import Foundation

final class FileTransfer {
    private let session: URLSession
    private let delegate: TransferDelegate
    private let code: String
    private let baseURL: URL

    init?(url: URL, code: String, fingerprint: String) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let root = components.url else { return nil }
        self.baseURL = root
        self.code = code
        let delegate = TransferDelegate(fingerprint: fingerprint)
        self.delegate = delegate
        let config = URLSessionConfiguration.ephemeral
        config.networkServiceType = .default
        config.httpMaximumConnectionsPerHost = 3
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 30
        // Large files may take longer than any fixed limit; timeoutIntervalForRequest catches stalls.
        config.timeoutIntervalForResource = 24 * 60 * 60
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func upload(fileURL: URL, destination: String, setClipboard: Bool, batchID: String?,
                onProgress: ((Int64, Int64) -> Void)? = nil,
                completion: @escaping (Result<String, Error>) -> Void) {
        guard let endpoint = URL(string: "/file", relativeTo: baseURL) else {
            completion(.failure(URLError(.badURL)))
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        if !code.isEmpty {
            request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        }
        let escapedName = fileURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? fileURL.lastPathComponent
        request.setValue(escapedName, forHTTPHeaderField: "X-Prilo-Filename")
        request.setValue(destination, forHTTPHeaderField: "X-Prilo-Destination")
        request.setValue(setClipboard ? "1" : "0", forHTTPHeaderField: "X-Prilo-Clipboard")
        if let batchID {
            request.setValue(batchID, forHTTPHeaderField: "X-Prilo-Batch")
        }
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let size = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if size >= 0 {
            request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        }
        let task = session.uploadTask(with: request, fromFile: fileURL)
        delegate.registerUpload(taskID: task.taskIdentifier, fallbackName: fileURL.lastPathComponent,
                                totalBytes: size, onProgress: onProgress, completion: completion)
        task.resume()
    }

    func download(file: OfferedFile, into directory: URL,
                  onProgress: ((Int64, Int64) -> Void)? = nil,
                  completion: @escaping (Result<URL, Error>) -> Void) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            completion(.failure(URLError(.badURL)))
            return
        }
        components.path = "/file/download"
        components.queryItems = [URLQueryItem(name: "id", value: file.id)]
        guard let endpoint = components.url else {
            completion(.failure(URLError(.badURL)))
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 300
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        if !code.isEmpty {
            request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        }
        let task = session.downloadTask(with: request)
        delegate.registerDownload(taskID: task.taskIdentifier, file: file, directory: directory,
                                  onProgress: onProgress, completion: completion)
        task.resume()
    }

    /// Gatekeeper then checks a received app or script before it first runs, as with a browser download.
    static func markQuarantined(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.quarantineProperties = [
            "LSQuarantineAgentName": "Fuso",
            "LSQuarantineType": "LSQuarantineTypeOtherDownload",
        ]
        do {
            try target.setResourceValues(values)
        } catch {
            Diagnostics.shared.record("file quarantine failed: \((error as NSError).code)")
        }
    }

    static func uniqueDestination(in directory: URL, name: String) -> URL {
        let fm = FileManager.default
        let first = directory.appendingPathComponent(name)
        if !fm.fileExists(atPath: first.path) {
            return first
        }
        let base = URL(fileURLWithPath: name)
        let ext = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        let cleanStem = stem.isEmpty ? "file" : stem
        for n in 2..<10000 {
            let candidateName = ext.isEmpty ? "\(cleanStem) (\(n))" : "\(cleanStem) (\(n)).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appendingPathComponent(UUID().uuidString + "-" + name)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) Б"
        }
        let kb = Double(bytes) / 1024.0
        if kb < 1024.0 {
            return String(format: "%.0f КБ", kb)
        }
        let mb = kb / 1024.0
        if mb < 100.0 {
            return String(format: "%.1f МБ", mb)
        }
        return String(format: "%.0f МБ", mb)
    }

    static func formatSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "" }
        let mb = bytesPerSecond / (1024.0 * 1024.0)
        if mb >= 1.0 {
            return String(format: "%.1f МБ/с", mb)
        }
        let kb = max(1.0, bytesPerSecond / 1024.0)
        return String(format: "%.0f КБ/с", kb)
    }
}

private final class TransferDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private struct UploadState {
        let fallbackName: String
        let totalBytes: Int64
        var bodyData = Data()
        let onProgress: ((Int64, Int64) -> Void)?
        let completion: (Result<String, Error>) -> Void
    }

    private struct DownloadState {
        let file: OfferedFile
        let directory: URL
        var movedURL: URL?
        var moveError: Error?
        let onProgress: ((Int64, Int64) -> Void)?
        let completion: (Result<URL, Error>) -> Void
    }

    private let pin: Pin
    private let lock = NSLock()
    private var uploads: [Int: UploadState] = [:]
    private var downloads: [Int: DownloadState] = [:]

    init(fingerprint: String) {
        self.pin = Pin(fingerprint)
    }

    func registerUpload(taskID: Int, fallbackName: String, totalBytes: Int64,
                        onProgress: ((Int64, Int64) -> Void)?,
                        completion: @escaping (Result<String, Error>) -> Void) {
        lock.lock()
        uploads[taskID] = UploadState(fallbackName: fallbackName, totalBytes: totalBytes,
                                      onProgress: onProgress, completion: completion)
        lock.unlock()
    }

    func registerDownload(taskID: Int, file: OfferedFile, directory: URL,
                          onProgress: ((Int64, Int64) -> Void)?,
                          completion: @escaping (Result<URL, Error>) -> Void) {
        lock.lock()
        downloads[taskID] = DownloadState(file: file, directory: directory,
                                          onProgress: onProgress, completion: completion)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        pin.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        pin.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock()
        let entry = uploads[task.taskIdentifier]
        lock.unlock()
        guard let entry, let cb = entry.onProgress else { return }
        let total = totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : entry.totalBytes
        DispatchQueue.main.async {
            cb(totalBytesSent, total)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if uploads[dataTask.taskIdentifier] != nil {
            uploads[dataTask.taskIdentifier]?.bodyData.append(data)
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let entry = downloads[downloadTask.taskIdentifier]
        let oversized = entry.map { totalBytesWritten > $0.file.size } ?? false
        if oversized {
            // The receiver announced this size in the offer; never accept more than that.
            downloads[downloadTask.taskIdentifier]?.moveError = URLError(.dataLengthExceedsMaximum)
        }
        lock.unlock()
        guard let entry else { return }
        if oversized {
            downloadTask.cancel()
            return
        }
        guard let cb = entry.onProgress else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : entry.file.size
        DispatchQueue.main.async {
            cb(min(totalBytesWritten, max(total, totalBytesWritten)), total)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        guard var entry = downloads[downloadTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 {
            do {
                let fm = FileManager.default
                let written = (try location.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                guard Int64(written) <= entry.file.size else { throw URLError(.dataLengthExceedsMaximum) }
                try fm.createDirectory(at: entry.directory, withIntermediateDirectories: true)
                let rawName = URL(fileURLWithPath: entry.file.name).lastPathComponent
                let safeName = (rawName.isEmpty || rawName == "." || rawName == "..") ? "file" : rawName
                let destination = FileTransfer.uniqueDestination(in: entry.directory, name: safeName)
                try fm.moveItem(at: location, to: destination)
                FileTransfer.markQuarantined(destination)
                entry.movedURL = destination
            } catch {
                entry.moveError = error
            }
        }
        downloads[downloadTask.taskIdentifier] = entry
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let upload = uploads.removeValue(forKey: task.taskIdentifier)
        let download = downloads.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        if let upload {
            if let error {
                DispatchQueue.main.async { upload.completion(.failure(error)) }
                return
            }
            guard let http = task.response as? HTTPURLResponse else {
                DispatchQueue.main.async { upload.completion(.failure(URLError(.badServerResponse))) }
                return
            }
            guard http.statusCode == 200 else {
                let err = NSError(domain: "PriloFileTransfer", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
                DispatchQueue.main.async { upload.completion(.failure(err)) }
                return
            }
            let savedName: String
            if let parsed = try? JSONDecoder().decode([String: AnyDecodableString].self, from: upload.bodyData),
               let name = parsed["name"]?.value, !name.isEmpty {
                savedName = name
            } else {
                savedName = upload.fallbackName
            }
            DispatchQueue.main.async { upload.completion(.success(savedName)) }
            return
        }

        if let download {
            if let error {
                let reported = download.moveError ?? error
                DispatchQueue.main.async { download.completion(.failure(reported)) }
                return
            }
            guard let http = task.response as? HTTPURLResponse else {
                DispatchQueue.main.async { download.completion(.failure(URLError(.badServerResponse))) }
                return
            }
            guard http.statusCode == 200 else {
                let err = NSError(domain: "PriloFileTransfer", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
                DispatchQueue.main.async { download.completion(.failure(err)) }
                return
            }
            if let movedURL = download.movedURL {
                DispatchQueue.main.async { download.completion(.success(movedURL)) }
            } else {
                DispatchQueue.main.async {
                    download.completion(.failure(download.moveError ?? URLError(.cannotCreateFile)))
                }
            }
        }
    }
}

private struct AnyDecodableString: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(String.self)
    }
}
