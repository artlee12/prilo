import Foundation

struct InputFrame: Encodable {
    let capture: UInt64
    let events: [Input]
}

struct ClipboardFrame: Encodable {
    let type = "clipboard"
    let clipboard: String
}

struct ClipboardImageFrame: Encodable {
    let type = "clipboardImage"
    let image: String
}

struct AwakeFrame: Encodable {
    let type = "awake"
    let awake: Bool
}

struct ShortcutFrame: Encodable {
    let type = "shortcut"
    let capture: UInt64
    let action: String
}

struct OfferedFile: Decodable, Equatable {
    let id: String
    let name: String
    let size: Int64
}

struct ChannelMessage: Decodable {
    let type: String
    let capture: UInt64?
    let text: String?
    let image: String?
    let files: [OfferedFile]?
}

final class InputChannel {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private var closed = false
    private var lastPing = Date.distantPast
    private var pendingPing: Date?
    private(set) var ready = false
    var onMessage: ((ChannelMessage) -> Void)?
    var onFailure: ((Response) -> Void)?

    init?(connection: Connection) {
        guard var url = URLComponents(url: connection.url, resolvingAgainstBaseURL: false) else { return nil }
        url.scheme = "wss"
        url.path = "/stream"
        guard let endpoint = url.url else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.networkServiceType = .responsiveData
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        session = URLSession(configuration: config, delegate: Pin(connection.fingerprint), delegateQueue: nil)
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(connection.code)", forHTTPHeaderField: "Authorization")
        // Older receivers ignore this; newer ones only push clipboard and file messages to clients that send it.
        request.setValue("sync", forHTTPHeaderField: "X-Prilo-Features")
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 12 * 1024 * 1024
    }

    func start() {
        task.resume()
        receive()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.ready, !self.closed else { return }
            self.fail(.failure(.timedOut))
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    deinit { session.invalidateAndCancel() }

    func heartbeat(now: Date, capturing: Bool) {
        guard ready, !closed else { return }
        if let pendingPing {
            if now.timeIntervalSince(pendingPing) >= (capturing ? 5.0 : 10.0) {
                fail(.failure(.timedOut))
            }
            return
        }
        guard now.timeIntervalSince(lastPing) >= (capturing ? 1.0 : 4.0) else { return }
        lastPing = now
        pendingPing = now
        task.sendPing { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                self.pendingPing = nil
                if let error {
                    self.fail(.failure((error as? URLError)?.code ?? .networkConnectionLost))
                }
            }
        }
    }

    func send(_ events: [Input], capture: UInt64, completion: @escaping () -> Void) {
        guard !closed, let payload = try? JSONEncoder().encode(InputFrame(capture: capture, events: events)) else {
            if !closed { fail(.failure(.cannotDecodeContentData)) }
            return
        }
        task.send(.data(payload)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                if let error {
                    self.fail(.failure((error as? URLError)?.code ?? .networkConnectionLost))
                } else {
                    completion()
                }
            }
        }
    }

    func sendClipboard(_ text: String) {
        guard !closed, let payload = try? JSONEncoder().encode(ClipboardFrame(clipboard: text)) else { return }
        task.send(.data(payload)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                if let error {
                    self.fail(.failure((error as? URLError)?.code ?? .networkConnectionLost))
                }
            }
        }
    }

    func sendClipboardImage(_ pngData: Data) {
        guard !closed, pngData.count <= maxClipboardImageBytes,
              let payload = try? JSONEncoder().encode(ClipboardImageFrame(image: pngData.base64EncodedString())) else { return }
        task.send(.data(payload)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                if let error {
                    self.fail(.failure((error as? URLError)?.code ?? .networkConnectionLost))
                }
            }
        }
    }

    func sendAwake(_ awake: Bool) {
        guard !closed, let payload = try? JSONEncoder().encode(AwakeFrame(awake: awake)) else { return }
        task.send(.data(payload)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                if let error {
                    self.fail(.failure((error as? URLError)?.code ?? .networkConnectionLost))
                }
            }
        }
    }

    func sendShortcut(_ action: String, capture: UInt64) {
        guard !closed, let payload = try? JSONEncoder().encode(ShortcutFrame(capture: capture, action: action)) else { return }
        task.send(.data(payload)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                if let error {
                    self.fail(.failure((error as? URLError)?.code ?? .networkConnectionLost))
                }
            }
        }
    }

    private func receive() {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                let data: Data
                switch result {
                case .success(.data(let body)): data = body
                case .success(.string(let text)): data = Data(text.utf8)
                case .failure(let error):
                    let status = (self.task.response as? HTTPURLResponse).map(\.statusCode).flatMap { $0 >= 400 ? $0 : nil }
                    self.fail(status.map(Response.http) ?? .failure((error as? URLError)?.code ?? .networkConnectionLost))
                    return
                @unknown default:
                    self.fail(.failure(.badServerResponse))
                    return
                }
                guard let message = try? JSONDecoder().decode(ChannelMessage.self, from: data) else {
                    self.fail(.failure(.badServerResponse))
                    return
                }
                if message.type == "ready" { self.ready = true }
                self.onMessage?(message)
                if !self.closed { self.receive() }
            }
        }
    }

    private func fail(_ response: Response) {
        close()
        onFailure?(response)
    }
}
