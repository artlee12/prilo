import AppKit
import Security
import SwiftUI

/// Checks GitHub Releases for a newer Prilo and installs it in place.
/// The new bundle must satisfy the running app's designated requirement, so only
/// builds signed with the same Prilo certificate can replace this copy.
final class UpdateModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case current
        case available(ReleaseInfo)
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: Self.automaticKey) }
    }
    var onChange: (() -> Void)?

    private static let automaticKey = "checkUpdatesAutomatically"
    private static let lastCheckKey = "lastUpdateCheck"
    private var timer: Timer?

    let current = ReleaseVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") ?? ReleaseVersion("0")!
    let repository = (Bundle.main.infoDictionary?["PriloUpdateRepository"] as? String) ?? ""

    init() {
        automatic = UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    var available: ReleaseInfo? {
        if case .available(let info) = phase { return info }
        return nil
    }

    var releasesPage: URL? { URL(string: "https://github.com/\(repository)/releases/latest") }

    /// Starts the daily background check.
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard automatic, phase != .checking, phase != .installing, available == nil else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        if Date().timeIntervalSince(last) >= 20 * 3600 { check(quiet: true) }
    }

    func check(quiet: Bool = false) {
        guard phase != .checking, phase != .installing else { return }
        guard repository.split(separator: "/").count == 2,
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            set(.failed("В этой сборке не указан репозиторий обновлений."))
            return
        }
        set(.checking)
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Prilo/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let info = data.flatMap(ReleaseInfo.parse)
            DispatchQueue.main.async {
                guard let self else { return }
                Diagnostics.shared.record("update check status=\(status) latest=\(info?.version.description ?? "none")")
                if error != nil || status == 0 {
                    self.set(quiet ? .idle : .failed("Нет связи с GitHub. Проверь интернет и повтори."))
                    return
                }
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                if status == 404 || (status == 200 && info == nil) {
                    self.set(.current)
                } else if status != 200 {
                    self.set(quiet ? .idle : .failed("GitHub ответил с кодом \(status). Повтори позже."))
                } else if let info, info.version > self.current {
                    self.set(.available(info))
                } else {
                    self.set(.current)
                }
            }
        }.resume()
    }

    /// Downloads, verifies and swaps in the new bundle, then relaunches Prilo.
    func install() {
        guard let info = available else { return }
        set(.installing)
        Diagnostics.shared.record("update download version=\(info.version)")
        URLSession.shared.downloadTask(with: info.download) { [weak self] location, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var failure: String?
            var staged: URL?
            if let location, error == nil, status == 200 {
                do {
                    staged = try Self.stage(location, expecting: info.version)
                } catch {
                    failure = error.localizedDescription
                }
            } else {
                failure = "Не удалось скачать обновление. Проверь интернет и повтори."
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard let staged else {
                    Diagnostics.shared.record("update failed: \(failure ?? "unknown")")
                    self.set(.failed(failure ?? "Обновление не установилось."))
                    return
                }
                do {
                    try self.replaceAndRelaunch(with: staged)
                } catch {
                    Diagnostics.shared.record("update replace failed code=\((error as NSError).code)")
                    self.set(.failed("Не удалось заменить приложение: \(error.localizedDescription) Скачай архив со страницы релиза вручную."))
                }
            }
        }.resume()
    }

    private func set(_ next: Phase) {
        phase = next
        onChange?()
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Unpacks the archive on the installed app's volume and checks the bundle inside.
    private static func stage(_ archive: URL, expecting version: ReleaseVersion) throws -> URL {
        let installed = Bundle.main.bundleURL
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                 appropriateFor: installed, create: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, folder.path]
        try unzip.run()
        unzip.waitUntilExit()
        let candidate = folder.appendingPathComponent("Prilo.app")
        guard unzip.terminationStatus == 0, FileManager.default.fileExists(atPath: candidate.path) else {
            throw UpdateError("Архив обновления повреждён.")
        }
        guard let plist = Bundle(url: candidate)?.infoDictionary,
              plist["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let shortVersion = plist["CFBundleShortVersionString"] as? String,
              ReleaseVersion(shortVersion) == version else {
            throw UpdateError("В архиве другая программа или другая версия.")
        }
        try verifySignature(of: candidate)
        return candidate
    }

    /// Accepts the bundle only if it meets the running app's designated requirement.
    private static func verifySignature(of bundle: URL) throws {
        var me: SecCode?
        var mine: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(bundle as CFURL, [], &candidate) == errSecSuccess, let candidate else {
            throw UpdateError("Не удалось проверить подпись обновления.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let result = SecStaticCodeCheckValidity(candidate, flags, requirement)
        guard result == errSecSuccess else {
            Diagnostics.shared.record("update signature rejected status=\(result)")
            throw UpdateError("Подпись обновления не совпадает с подписью Prilo. Обновление отклонено.")
        }
    }

    private func replaceAndRelaunch(with candidate: URL) throws {
        let installed = Bundle.main.bundleURL
        _ = try FileManager.default.replaceItemAt(installed, withItemAt: candidate, backupItemName: nil, options: [])
        try? FileManager.default.removeItem(at: candidate.deletingLastPathComponent())
        Diagnostics.shared.record("update installed, relaunching")
        // A tiny shell waits for this process to exit, then opens the new copy.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                              "prilo-relaunch", String(ProcessInfo.processInfo.processIdentifier), installed.path]
        try relaunch.run()
        (NSApp.delegate as? PriloApp)?.quitForUpdate()
    }
}

/// The «Обновления» section of the settings pane.
struct UpdateSection: View {
    @ObservedObject var model: UpdateModel

    var body: some View {
        Section {
            LabeledContent("Установлена версия", value: model.current.description)
            HStack(spacing: 10) {
                switch model.phase {
                case .checking:
                    ProgressView().controlSize(.small)
                    Text("Проверяем…").foregroundStyle(.secondary)
                case .installing:
                    ProgressView().controlSize(.small)
                    Text("Скачиваем и устанавливаем…").foregroundStyle(.secondary)
                case .current:
                    Label("Установлена последняя версия", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                case .available(let info):
                    Label("Доступна версия \(info.version.description)", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.tint)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                case .idle:
                    EmptyView()
                }
                Spacer()
                if model.available != nil {
                    Button("Установить и перезапустить") { model.install() }
                        .prominentActionStyle()
                } else {
                    Button("Проверить обновления") { model.check() }
                        .disabled(model.phase == .checking || model.phase == .installing)
                }
            }
            if let info = model.available, !info.notes.isEmpty {
                Text(info.notes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(12)
            }
            Toggle("Проверять обновления автоматически", isOn: $model.automatic)
        } header: {
            Text("Обновления")
        } footer: {
            if let page = model.releasesPage {
                Link("Все версии на GitHub", destination: page)
            }
        }
    }
}
