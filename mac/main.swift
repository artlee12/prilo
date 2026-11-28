import AppKit
import Carbon.HIToolbox
import CryptoKit
import Darwin
import Security

private final class CaptureKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class Pin: NSObject, URLSessionDelegate, @unchecked Sendable {
    let fingerprint: String

    init(_ fingerprint: String) { self.fingerprint = fingerprint }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first else {
            Diagnostics.shared.record("tls certificate unavailable")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let hash = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
        guard hash == fingerprint else {
            Diagnostics.shared.record("tls fingerprint mismatch")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum Response {
    case http(Int)
    case failure(URLError.Code)

    var description: String {
        switch self {
        case .http(let status): return "HTTP \(status)"
        case .failure(let code): return "URLError \(code.rawValue)"
        }
    }
}

final class Connection {
    let url: URL
    let code: String
    let fingerprint: String
    let session: URLSession
    private var inFlight = false
    private var afterSend: (() -> Void)?

    init(url: URL, code: String, fingerprint: String) {
        self.url = url
        self.code = code
        self.fingerprint = fingerprint
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 4
        session = URLSession(configuration: config, delegate: Pin(fingerprint), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func send(_ events: [Input], completion: @escaping (Response) -> Void) {
        perform(method: "POST", body: try? JSONEncoder().encode(events), timeout: events.isEmpty ? 3 : 1.5,
                completion: completion)
    }

    func perform(method: String, body: Data? = nil, timeout: Double = 3, completion: @escaping (Response) -> Void) {
        performData(method: method, body: body, timeout: timeout) { response, _ in completion(response) }
    }

    func performData(method: String, body: Data? = nil, timeout: Double = 3, endpoint: URL? = nil,
                     completion: @escaping (Response, Data?) -> Void) {
        var request = URLRequest(url: endpoint ?? url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if !code.isEmpty { request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        inFlight = true
        session.dataTask(with: request) { [self] data, response, error in
            let result: Response
            if let error {
                result = .failure((error as? URLError)?.code ?? .unknown)
            } else if let response = response as? HTTPURLResponse {
                result = .http(response.statusCode)
            } else {
                result = .failure(.badServerResponse)
            }
            DispatchQueue.main.async {
                self.inFlight = false
                let followUp = self.afterSend
                self.afterSend = nil
                completion(result, data)
                followUp?()
            }
        }.resume()
    }

    func releaseWhenIdle(completion: @escaping () -> Void) {
        let release = {
            self.send([Input(kind: "release")]) { result in
                Diagnostics.shared.record("disconnect release \(result.description)")
                completion()
            }
        }
        if inFlight {
            afterSend = release
        } else {
            release()
        }
    }
}

final class PriloApp: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    let status = NSMenuItem(title: "Отключено", action: nil, keyEquivalent: "")
    var connection: Connection?
    var channel: InputChannel?
    var captureID: UInt64 = 0
    var captureFrames = 0
    var capturePeakQueue = 0
    var capturePeakWrite: UInt64 = 0
    var reconnect: ConnectionWindow.Credentials?
    var retryAt: Date?
    var retryDelay: TimeInterval = 0.8
    var reconnectPaused = false
    let discovery = Discovery()
    var tap: CFMachPort?
    var tapSource: CFRunLoopSource?
    var gestureTap: CFMachPort?
    var gestureTapSource: CFRunLoopSource?
    var captureKeyEvents = 0
    var secureInputWarned = false
    var timer: Timer?
    var sending = false
    var ready = false
    var linked = false
    var releasing: Connection?
    var quitting = false
    var paused = false
    var window: ConnectionWindow!
    var pauseItem: NSMenuItem!
    var sendFileItem: NSMenuItem!
    var receiveFileItem: NSMenuItem!
    var lockItem: NSMenuItem!
    var disconnectItem: NSMenuItem!
    var inputState: Bool?
    var attemptedTap = false
    var lastInputCheck = Date.distantPast
    var topEdgePush = TopEdgePush()
    let log = Diagnostics.shared
    let profiles = Profiles()
    let controlSettings = ControlSettings()
    let cue = HandoffCue()
    let fileDropBar = FileDropBar()
    var fileTransfer: FileTransfer?
    var receiverSupportsShortcuts = false
    var receiverSupportsFiles = false
    var receiverSupportsSync = false
    var backgroundCursorEnabled = false
    var keyboard = RemoteKeyboard(commandIsControl: true)
    var pointer = PointerMotion(speed: 1)
    var scrollMotion = ScrollMotion(smoothness: 1.0)
    var swipeDetector = ThreeFingerSwipeDetector()
    var pinchDetector = PinchZoomDetector()
    var suppressedShortcutKeys: Set<Int64> = []
    private static let gestureEventTypes: Set<UInt32> = [18, 19, 20, 29, 30, 31, 32, 33, 34, 37, 38]
    var capturedBounds = CGRect.zero
    var lastWarp = Date.distantPast
    var lastActivateAttempt = Date.distantPast
    var lastReinforce = Date.distantPast
    var pendingFinderSendURLs: [URL] = []
    var cachedTransferredFiles: [String: URL] = [:]
    var lastReceivedFiles: [URL] = []
    var showLastReceivedItem: NSMenuItem!
    var offeredWindowsFiles: [OfferedFile] = []
    var offerGeneration: UInt64 = 0
    var latencyActivity: NSObjectProtocol?
    let clipboardQueue = DispatchQueue(label: "com.artlee12.prilo.clipboard", qos: .utility)
    var captureAnchor: NSPanel?
    var handoffConfirmed = false
    var remote = false
    var previousApp: NSRunningApplication?
    var cursorHidden = false
    var cursorDetached = false
    var pending: [Input] = []
    var entry = CGPoint.zero
    var lastSend = Date.distantPast
    var localButtons: Set<UInt16> = []
    var localKeys: Set<Int64> = []
    var lastClipboardChangeCount = NSPasteboard.general.changeCount
    var lastClipboardCheck = Date.distantPast
    var lastSyncedClipboardHash: Data?
    var macLocked = false
    var lastSentAwake: Bool?
    var lockObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        log.record("startup version=\(version) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        backgroundCursorEnabled = enableBackgroundCursorControl()
        log.record("background cursor control=\(backgroundCursorEnabled)")
        installMainMenu()
        window = ConnectionWindow(owner: self)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let symbol = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Prilo") {
            symbol.isTemplate = true
            item.button?.image = symbol
        } else {
            item.button?.title = "Prilo"
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(menuItem("Открыть Prilo", action: #selector(showWindow)))
        pauseItem = menuItem("Приостановить управление", action: #selector(togglePause))
        sendFileItem = menuItem("Отправить файл на Windows…", action: #selector(pickAndSendFiles))
        receiveFileItem = menuItem("Сохранить файл с Windows", action: #selector(downloadOfferedFiles))
        receiveFileItem.isHidden = true
        showLastReceivedItem = menuItem("Показать последний файл в Finder", action: #selector(revealLastReceivedFiles))
        showLastReceivedItem.isHidden = true
        lockItem = menuItem("Заблокировать Windows", action: #selector(lockWindows))
        disconnectItem = menuItem("Отключить Windows", action: #selector(disconnect))
        menu.addItem(pauseItem)
        menu.addItem(sendFileItem)
        menu.addItem(receiveFileItem)
        menu.addItem(showLastReceivedItem)
        menu.addItem(lockItem)
        menu.addItem(disconnectItem)
        menu.addItem(.separator())
        menu.addItem(updateItem)
        menu.addItem(menuItem("Скопировать журнал", action: #selector(copyDiagnostics)))
        menu.addItem(menuItem("Выйти из Prilo", action: #selector(quit)))
        item.menu = menu
        NSApp.servicesProvider = self
        QuickActionInstaller.installIfNeeded()

        timer = Timer(timeInterval: 0.006, repeats: true) { [weak self] _ in self?.tick() }
        if let timer {
            timer.tolerance = 0
            RunLoop.main.add(timer, forMode: .common)
        }
        display(.idle)
        refreshPermissions()
        showWindow()
        window.updateProfiles(profiles.items, selected: profiles.last)
        discovery.didChange = { [weak self] peers in
            guard let self else { return }
            self.window.updateNearby(peers.count)
            if let reconnect = self.reconnect,
               let peer = peers.first(where: { $0.fingerprint == reconnect.fingerprint }) {
                let updated = reconnect.atHost(peer.host)
                self.reconnect = updated
                if self.connection == nil {
                    self.window.updateAddress(peer.host)
                    self.retryAt = Date()
                } else if !self.linked, self.connection?.url.host != peer.host {
                    let savedPaused = self.paused || self.reconnectPaused
                    self.stop()
                    self.reconnect = updated
                    self.reconnectPaused = savedPaused
                    self.window.updateAddress(peer.host)
                    self.retryAt = Date().addingTimeInterval(0.1)
                }
            }
        }
        if let profile = profiles.last, selectProfile(profile), controlSettings.autoConnect {
            reconnect = window.credentials()
            retryAt = Date().addingTimeInterval(1.2)
        }
        discovery.start()
        window.model.updates.onChange = { [weak self] in self?.refreshUpdateItem() }
        window.model.updates.start()
        installLockObservers()
    }

    func installLockObservers() {
        let distributed = DistributedNotificationCenter.default()
        lockObservers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.handleMacLocked()
        })
        lockObservers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.handleMacUnlocked()
        })
        let workspace = NSWorkspace.shared.notificationCenter
        lockObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleMacLocked()
        })
        lockObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleMacWake()
        })
    }

    func handleMacWake() {
        handleMacUnlocked()
        discovery.restart()
        if connection == nil, releasing == nil, reconnect != nil, controlSettings.autoConnect {
            retryDelay = 0.8
            retryAt = Date().addingTimeInterval(0.8)
        }
    }

    func handleMacLocked() {
        macLocked = true
        if remote { leave(reason: "Mac locked") }
        syncAwakeIfNeeded()
        if linked && controlSettings.lockWindowsOnMacLock {
            lockWindows()
        }
    }

    func handleMacUnlocked() {
        macLocked = false
        syncAwakeIfNeeded()
    }

    func syncAwakeIfNeeded() {
        guard linked, receiverSupportsSync, let channel, channel.ready else { return }
        let desired = !macLocked && controlSettings.keepWindowsAwake
        guard desired != lastSentAwake else { return }
        lastSentAwake = desired
        channel.sendAwake(desired)
    }

    @objc func lockWindows() {
        guard let active = connection,
              var components = URLComponents(url: active.url, resolvingAgainstBaseURL: false) else { return }
        components.path = "/power/lock"
        guard let lockURL = components.url else { return }
        if remote { leave(reason: "lock windows") }
        let powerConnection = Connection(url: lockURL, code: powerCode(accessCode: active.code), fingerprint: active.fingerprint)
        powerConnection.perform(method: "POST") { [weak self] result in
            self?.log.record("lock windows \(result.description)")
        }
    }

    lazy var updateItem: NSMenuItem = menuItem("Проверить обновления…", action: #selector(showUpdates))

    func refreshUpdateItem() {
        let available = window.model.updates.available
        updateItem.title = available.map { "Установить Prilo \($0.version.description)…" } ?? "Проверить обновления…"
    }

    /// Opens the settings pane, where the update section lives, and checks if nothing is pending.
    @objc func showUpdates() {
        showWindow()
        window.model.pane = .settings
        if window.model.updates.available == nil { window.model.updates.check() }
    }

    /// Quits after an update was installed; the relaunch helper opens the new copy.
    func quitForUpdate() {
        NSApp.terminate(nil)
    }

    func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    func installMainMenu() {
        let bar = NSMenu()
        let appMenu = NSMenu(title: "Prilo")
        appMenu.addItem(menuItem("Открыть Prilo", action: #selector(showWindow), key: ","))
        appMenu.addItem(menuItem("Закрыть окно", action: #selector(closeWindow), key: "w"))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("Выйти из Prilo", action: #selector(quit), key: "q"))
        let appEntry = NSMenuItem()
        appEntry.submenu = appMenu
        bar.addItem(appEntry)

        let edit = NSMenu(title: "Правка")
        for (title, action, key) in [("Вырезать", #selector(NSText.cut(_:)), "x"),
                                     ("Копировать", #selector(NSText.copy(_:)), "c"),
                                     ("Вставить", #selector(NSText.paste(_:)), "v"),
                                     ("Выбрать всё", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        let editEntry = NSMenuItem()
        editEntry.submenu = edit
        bar.addItem(editEntry)
        NSApp.mainMenu = bar
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handleFinderSendRequest(urls)
    }

    @objc func sendFilesFromService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = extractDraggedFileURLs(from: pboard)
        guard !urls.isEmpty else {
            error.pointee = "Не найдены файлы для отправки" as NSString
            return
        }
        handleFinderSendRequest(urls)
    }

    private func handleFinderSendRequest(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if linked && receiverSupportsFiles {
            prepareAndSendToWindows(urls)
        } else {
            pendingFinderSendURLs = urls
            fileDropBar.showStatus("Подключаемся к Windows — отправим после соединения…",
                                   on: builtInScreen(), duration: 3.5)
            if connection == nil, releasing == nil, let reconnect {
                beginConnection(reconnect)
            }
        }
    }

    @objc func showWindow() {
        if remote { leave(reason: "window opened") }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func closeWindow() { window.orderOut(nil) }

    @discardableResult
    func selectProfile(_ profile: PCProfile) -> Bool {
        cancelAutomaticConnection()
        var secrets: PCSecrets?
        do {
            secrets = try profiles.load(profile.id)
        } catch {
            log.record("keychain load failed code=\((error as NSError).code)")
        }
        window.loadProfile(profile, secrets: secrets)
        return secrets != nil
    }

    func forgetProfile(_ profile: PCProfile) -> Bool {
        do {
            try profiles.forget(profile.id)
            window.updateProfiles(profiles.items, selected: nil)
            log.record("profile forgotten")
            return true
        } catch {
            log.record("keychain delete failed code=\((error as NSError).code)")
            window.notice = "Не удалось удалить сохранённые данные из Связки ключей."
            return false
        }
    }

    @discardableResult
    func renameProfile(_ profile: PCProfile, to name: String) -> PCProfile? {
        do {
            guard let renamed = try profiles.rename(profile.id, to: name) else { return nil }
            let selected = profiles.items.first { $0.id == window.model.profileID }
            window.updateProfiles(profiles.items, selected: selected)
            if let saved = reconnect, saved.id == renamed.id {
                reconnect = ConnectionWindow.Credentials(id: saved.id, name: renamed.name, host: saved.host,
                                                         code: saved.code, fingerprint: saved.fingerprint)
            }
            log.record("profile renamed")
            return renamed
        } catch {
            window.notice = "Не удалось сохранить новое имя ПК."
            return nil
        }
    }

    func cancelAutomaticConnection() {
        reconnect = nil
        retryAt = nil
        retryDelay = 3
        reconnectPaused = false
    }

    @objc func connect() {
        guard connection == nil, releasing == nil else { return }
        cancelAutomaticConnection()
        guard let credentials = window.credentials() else {
            log.record("connect blocked invalid form")
            return
        }
        beginConnection(credentials)
    }

    func pair(_ peer: NearbyPC, code: PairingCode) {
        guard connection == nil, releasing == nil else { return }
        cancelAutomaticConnection()
        guard peer.fingerprint.hasPrefix(code.prefix) else {
            display(.error("Код не совпадает с выбранным ПК. Проверь имя ПК и код в окне Prilo Receiver."))
            return
        }
        guard let endpoint = URL(string: "https://\(peer.host):43821/pair"),
              let body = try? JSONEncoder().encode(["pin": code.pin]) else { return }
        display(.connecting)
        let attempt = Connection(url: endpoint, code: "", fingerprint: peer.fingerprint)
        connection = attempt
        attempt.performData(method: "POST", body: body) { [weak self, weak attempt] result, body in
            guard let self, let attempt, self.connection === attempt else { return }
            self.log.record("pair result \(result.description)")
            self.connection = nil
            switch result {
            case .http(200):
                let values = body.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
                guard let token = values?["code"], token.utf8.count == 32,
                      token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    self.display(.error("Приёмник вернул некорректные данные сопряжения."))
                    return
                }
                let existing = self.profiles.items.first { $0.receiverID == peer.fingerprint }
                    ?? self.profiles.items.first {
                        $0.receiverID == nil && $0.host == peer.host &&
                            (try? self.profiles.load($0.id))?.fingerprint == peer.fingerprint
                    }
                let credentials = ConnectionWindow.Credentials(id: existing?.id,
                    name: existing?.name ?? String(peer.name.prefix(60)), host: peer.host,
                    code: token, fingerprint: peer.fingerprint)
                self.window.fillCredentials(credentials)
                self.beginConnection(credentials)
            case .http(401):
                self.display(.error("Код использован, истёк или введён неверно. Возьми новый код в меню Prilo в трее Windows."))
            default:
                self.display(.error(self.connectionMessage(result)))
            }
        }
    }

    func beginConnection(_ saved: ConnectionWindow.Credentials) {
        guard connection == nil, releasing == nil else { return }
        let peer = discovery.computers.first { $0.fingerprint == saved.fingerprint }
        let credentials = saved.atHost(peer?.host ?? saved.host)
        guard let url = URL(string: "https://\(credentials.host):43821/input"),
              let device = URL(string: "https://\(credentials.host):43821/device") else { return }
        let attempt = Connection(url: url, code: credentials.code, fingerprint: credentials.fingerprint)
        connection = attempt
        display(.connecting)
        log.record("connect started")
        attempt.performData(method: "GET", endpoint: device) { [weak self, weak attempt] result, data in
            guard let self, let attempt, self.connection === attempt else { return }
            self.log.record("device probe \(result.description)")
            switch result {
            case .http(200):
                let capabilities = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
                guard capabilities?["stream"] == "1", let stream = InputChannel(connection: attempt) else {
                    self.connectionFailed(.failure(.badServerResponse))
                    return
                }
                self.receiverSupportsShortcuts = capabilities?["shortcut"] == "1"
                self.receiverSupportsFiles = capabilities?["files"] == "1"
                self.receiverSupportsSync = capabilities?["sync"] == "1"
                self.fileTransfer = self.receiverSupportsFiles
                    ? FileTransfer(url: attempt.url, code: credentials.code, fingerprint: credentials.fingerprint)
                    : nil
                let wake = WakeTarget(mac: capabilities?["mac"] ?? "", broadcast: capabilities?["broadcast"] ?? "")
                self.channel = stream
                stream.onMessage = { [weak self, weak stream] event in
                    guard let self, let stream, self.channel === stream else { return }
                    if event.type == "ready", !self.linked {
                        self.finishConnection(credentials, wake: wake)
                    } else {
                        self.handleChannelMessage(event)
                    }
                }
                stream.onFailure = { [weak self, weak stream] result in
                    guard let self, let stream, self.channel === stream else { return }
                    self.connectionFailed(result)
                }
                stream.start()
            case .http(404):
                attempt.send([]) { [weak self, weak attempt] result in
                    guard let self, let attempt, self.connection === attempt else { return }
                    if case .http(204) = result {
                        self.finishConnection(credentials, wake: nil)
                    } else {
                        self.connectionFailed(result)
                    }
                }
            default:
                self.connectionFailed(result)
            }
        }
    }

    func finishConnection(_ credentials: ConnectionWindow.Credentials, wake: WakeTarget?) {
        log.record(channel == nil ? "connection ready legacy HTTPS" : "connection ready WebSocket")
        UserDefaults.standard.set(credentials.host, forKey: "address")
        linked = true
        paused = reconnectPaused
        reconnectPaused = false
        attemptedTap = false
        lastSend = Date()
        lastClipboardChangeCount = NSPasteboard.general.changeCount
        lastSyncedClipboardHash = nil
        lastSentAwake = nil
        retryDelay = 0.8
        if latencyActivity == nil {
            latencyActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "Prilo remote input"
            )
        }
        refreshPermissions()
        updateControlStatus()
        refreshFileMenuItems()
        syncAwakeIfNeeded()
        do {
            let saved = try profiles.remember(name: credentials.name, host: credentials.host,
                                               id: credentials.id, secrets: PCSecrets(code: credentials.code,
                                               fingerprint: credentials.fingerprint), wake: wake)
            window.updateProfiles(profiles.items, selected: saved)
            window.updateAddress(saved.host)
            if controlSettings.autoConnect {
                reconnect = ConnectionWindow.Credentials(id: saved.id, name: saved.name, host: saved.host,
                    code: credentials.code, fingerprint: credentials.fingerprint)
            }
        } catch {
            log.record("keychain save failed code=\((error as NSError).code)")
            window.notice = "Подключение работает. Связка ключей не сохранила данные для следующего запуска."
        }
        if !pendingFinderSendURLs.isEmpty && receiverSupportsFiles {
            let queued = pendingFinderSendURLs
            pendingFinderSendURLs.removeAll()
            prepareAndSendToWindows(queued)
        }
    }

    func connectionFailed(_ result: Response) {
        log.record("connection lost \(result.description)")
        let failedHost = connection?.url.host
        let wasPaused = paused || reconnectPaused
        stop()
        switch result {
        case .failure(.serverCertificateUntrusted), .failure(.serverCertificateHasUnknownRoot),
             .failure(.secureConnectionFailed), .failure(.userCancelledAuthentication), .failure(.cancelled):
            if reconnect != nil && controlSettings.autoConnect {
                reconnectPaused = wasPaused
                retryAt = nil
                display(.error("Сохранённый адрес ответил с другой подписью. Ждём обнаружения твоего ПК по его отпечатку."))
                return
            }
        case .failure(.timedOut), .failure(.cannotConnectToHost), .failure(.notConnectedToInternet),
             .failure(.networkConnectionLost), .failure(.cannotFindHost), .http(409):
            if let saved = reconnect, controlSettings.autoConnect {
                reconnectPaused = wasPaused
                if let peer = discovery.computers.first(where: { $0.fingerprint == saved.fingerprint }),
                   peer.host != failedHost {
                    reconnect = saved.atHost(peer.host)
                    window.updateAddress(peer.host)
                    retryAt = Date().addingTimeInterval(0.3)
                    return
                }
                retryAt = Date().addingTimeInterval(retryDelay)
                retryDelay = min(retryDelay * 2, 15)
                display(.error(connectionMessage(result) + " Prilo попробует подключиться снова."))
                return
            }
        default: break
        }
        cancelAutomaticConnection()
        display(.error(connectionMessage(result)))
    }

    func handleChannelMessage(_ message: ChannelMessage) {
        switch message.type {
        case "entered" where remote && message.capture == captureID:
            handoffConfirmed = true
            if controlSettings.animate { cue.show(at: entry, entering: true) }
        case "returned" where remote && message.capture == captureID:
            leave(reason: "Windows edge")
        case "layout" where remote && message.capture == captureID:
            if controlSettings.showLayoutIndicator, let lang = message.text, !lang.isEmpty {
                fileDropBar.showLayoutBadge(lang, on: builtInScreen())
            }
        case "clipboard":
            if let text = message.text { applyRemoteClipboard(text) }
        case "clipboardImage":
            if let image = message.image { applyRemoteClipboardImage(image) }
        case "fileOffer":
            if let files = message.files, !files.isEmpty { handleRemoteFileOffer(files) }
        case "fileDrop":
            if let files = message.files, !files.isEmpty { handleRemoteFileDrop(files) }
        case "inputUnavailable": connectionFailed(.http(503))
        case "invalid": connectionFailed(.failure(.cannotParseResponse))
        default: break
        }
    }

    func connectionMessage(_ result: Response) -> String {
        switch result {
        case .http(401):
            return "Код доступа не подошёл. Скопируй его заново из пункта «Данные для ручного подключения…» в трее Windows."
        case .http(409):
            return "Другой Mac уже держит канал управления этим ПК. Отключи его и попробуй снова."
        case .http(503):
            return "Windows не смогла принять ввод. Проверь, что рабочий стол Windows разблокирован."
        case .failure(.serverCertificateUntrusted), .failure(.serverCertificateHasUnknownRoot),
             .failure(.secureConnectionFailed), .failure(.userCancelledAuthentication), .failure(.cancelled):
            return "Не удалось подтвердить сертификат. Сверь отпечаток с пунктом «Данные для ручного подключения…» в трее Windows."
        case .failure(.timedOut), .failure(.cannotConnectToHost), .failure(.notConnectedToInternet),
             .failure(.networkConnectionLost):
            return result.unreachableHint ?? "Приёмник не ответил. Проверь IP, локальную сеть и доступ Prilo к ней в настройках macOS."
        default:
            return "Получен неожиданный ответ (\(result.description)). Проверь журнал приёмника в трее Windows и журнал Prilo."
        }
    }

    @objc func openPrivacy() {
        openSettings("Privacy_Accessibility", name: "accessibility")
    }

    @objc func openInputMonitoring() {
        openSettings("Privacy_ListenEvent", name: "input monitoring")
    }

    func openSettings(_ pane: String, name: String) {
        log.record("settings requested \(name)")
        guard let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"),
              NSWorkspace.shared.open(settings) else {
            window.notice = "Открой вручную «Системные настройки → Конфиденциальность и безопасность»."
            return
        }
    }

    @objc func recheckPermissions() {
        log.record("permissions recheck requested")
        attemptedTap = false
        refreshPermissions()
        if linked { updateControlStatus() }
    }

    func refreshPermissions() {
        let allowed = AXIsProcessTrusted()
        let monitoring = CGPreflightListenEventAccess()
        let changed = inputState != allowed || window.inputMonitoring != monitoring
        if changed {
            log.record("permissions accessibility=\(allowed) inputMonitoring=\(monitoring)")
            inputState = allowed
            attemptedTap = false
            window.setPermissions(accessibility: allowed, monitoring: monitoring)
        }
        let wasReady = ready
        if !allowed {
            if ready { leave(reason: "accessibility revoked") }
            ready = false
            removeTap()
        } else if linked && !paused && tap == nil && !attemptedTap {
            attemptedTap = true
            ready = installTap()
            log.record("input tap installed=\(ready)")
        }
        if linked && (changed || wasReady != ready) { updateControlStatus() }
    }

    @objc func togglePause() {
        guard linked else { return }
        paused.toggle()
        log.record(paused ? "control paused" : "control resumed")
        if paused {
            leave(reason: "paused")
            ready = false
            removeTap()
            localKeys.removeAll()
            localButtons.removeAll()
        } else {
            attemptedTap = false
            refreshPermissions()
        }
        updateControlStatus()
    }

    @objc func copyDiagnostics() {
        let text = log.recent()
        guard !text.isEmpty else {
            window.notice = "Журнал пока недоступен. Попробуй после подключения."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        window.notice = "Последние записи журнала скопированы."
    }

    @objc func revealDiagnostics() {
        log.drain()
        NSWorkspace.shared.activateFileViewerSelecting([log.file])
    }

    func display(_ state: ConnectionWindow.State) {
        status.title = state.title
        pauseItem.isEnabled = linked
        pauseItem.title = paused ? "Возобновить управление" : "Приостановить управление"
        refreshFileMenuItems()
        lockItem.isEnabled = linked
        disconnectItem.isEnabled = connection != nil
        window.render(state)
    }

    func refreshFileMenuItems() {
        sendFileItem?.isEnabled = linked && receiverSupportsFiles
        guard let receiveFileItem else { return }
        if !linked || !receiverSupportsFiles || offeredWindowsFiles.isEmpty {
            receiveFileItem.isHidden = true
            return
        }
        receiveFileItem.isHidden = false
        if offeredWindowsFiles.count == 1, let first = offeredWindowsFiles.first {
            receiveFileItem.title = "Сохранить с Windows: \(first.name) (\(FileTransfer.formatBytes(first.size)))"
        } else {
            let total = offeredWindowsFiles.reduce(Int64(0)) { $0 + $1.size }
            receiveFileItem.title = "Сохранить с Windows: \(offeredWindowsFiles.count) файлов (\(FileTransfer.formatBytes(total)))"
        }
    }

    private func builtInScreen() -> NSScreen? {
        let targetID = CGGetOnlineBuiltInDisplay()
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == targetID
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    @objc func revealLastReceivedFiles() {
        guard !lastReceivedFiles.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(lastReceivedFiles)
    }

    @objc func pickAndSendFiles() {
        guard linked, receiverSupportsFiles else { return }
        if remote { leave(reason: "file picker") }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Отправить на Windows"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            prepareAndSendToWindows(panel.urls)
        }
    }

    func prepareAndSendToWindows(_ rawURLs: [URL]) {
        guard linked, receiverSupportsFiles else { return }
        let candidates = Array(rawURLs.prefix(20))
        guard !candidates.isEmpty else { return }
        let hasDir = candidates.contains { url in
            let resolved = (url as NSURL).filePathURL ?? url
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) && isDir.boolValue
        }
        if !hasDir {
            sendFilesToWindows(candidates, destination: "downloads")
            return
        }
        fileDropBar.showProgress("Упаковываем папку в ZIP…", fraction: 0.08, on: builtInScreen())
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let stagingDir = fm.temporaryDirectory.appendingPathComponent("prilo-zip-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            var prepared: [URL] = []
            for raw in candidates {
                let url = (raw as NSURL).filePathURL ?? raw
                var isDir: ObjCBool = false
                guard url.isFileURL, fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if !isDir.boolValue {
                    prepared.append(url)
                    continue
                }
                let baseName = url.lastPathComponent.isEmpty ? "folder" : url.lastPathComponent
                let zipURL = FileTransfer.uniqueDestination(in: stagingDir, name: "\(baseName).zip")
                DispatchQueue.main.async {
                    self.fileDropBar.showProgress("Упаковываем «\(baseName)» в ZIP…", fraction: 0.12, on: self.builtInScreen())
                }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                proc.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", url.path, zipURL.path]
                proc.standardOutput = Pipe()
                proc.standardError = Pipe()
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0, fm.fileExists(atPath: zipURL.path) {
                        prepared.append(zipURL)
                    }
                } catch {
                    self.log.record("zip folder failed: \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                guard !prepared.isEmpty else {
                    try? fm.removeItem(at: stagingDir)
                    self.fileDropBar.showStatus("Не удалось подготовить файлы для отправки",
                                                on: self.builtInScreen(), duration: 3.0)
                    return
                }
                self.sendFilesToWindows(prepared, destination: "downloads", cleanupDir: stagingDir)
            }
        }
    }

    @objc func downloadOfferedFiles() {
        guard linked, receiverSupportsFiles, let transfer = fileTransfer, !offeredWindowsFiles.isEmpty else { return }
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let batch = offeredWindowsFiles
        transferBatchFromWindows(batch, using: transfer, into: downloadsDir, logPrefix: "downloaded")
    }

    private func downloadBatch(_ files: [OfferedFile], using transfer: FileTransfer, into directory: URL,
                               onProgress: @escaping (Int64, Int64, Double) -> Void,
                               completion: @escaping ([URL], Error?) -> Void) {
        let totalExpected = max(Int64(1), files.reduce(Int64(0)) { $0 + max(0, $1.size) })
        let start = Date()
        var perFileBytes = [Int64](repeating: 0, count: files.count)
        var results = [URL?](repeating: nil, count: files.count)
        var firstError: Error?
        var nextIndex = 0
        var active = 0
        let maxConcurrent = min(3, files.count)
        var lastHUDUpdate = Date.distantPast
        let fm = FileManager.default

        func emitProgress(force: Bool = false) {
            let now = Date()
            guard force || now.timeIntervalSince(lastHUDUpdate) >= 0.08 else { return }
            lastHUDUpdate = now
            let done = perFileBytes.reduce(Int64(0), +)
            let elapsed = max(0.05, now.timeIntervalSince(start))
            onProgress(done, totalExpected, Double(done) / elapsed)
        }

        func pump() {
            while active < maxConcurrent && nextIndex < files.count {
                let idx = nextIndex
                nextIndex += 1
                active += 1
                let file = files[idx]
                if let cached = cachedTransferredFiles[file.id],
                   let attrs = try? fm.attributesOfItem(atPath: cached.path),
                   (attrs[.size] as? NSNumber)?.int64Value == file.size {
                    let destination = FileTransfer.uniqueDestination(in: directory, name: cached.lastPathComponent)
                    if (try? fm.copyItem(at: cached, to: destination)) != nil {
                        perFileBytes[idx] = file.size
                        results[idx] = destination
                        cachedTransferredFiles[file.id] = destination
                        active -= 1
                        emitProgress(force: true)
                        continue
                    }
                }
                transfer.download(file: file, into: directory, onProgress: { written, _ in
                    perFileBytes[idx] = min(max(0, file.size), written)
                    emitProgress()
                }) { result in
                    switch result {
                    case .success(let url):
                        perFileBytes[idx] = max(0, file.size)
                        results[idx] = url
                        self.cachedTransferredFiles[file.id] = url
                    case .failure(let error):
                        if firstError == nil { firstError = error }
                    }
                    active -= 1
                    emitProgress(force: true)
                    if active == 0 && nextIndex >= files.count {
                        completion(results.compactMap { $0 }, firstError)
                    } else {
                        pump()
                    }
                }
            }
            if active == 0 && nextIndex >= files.count {
                completion(results.compactMap { $0 }, firstError)
            }
        }
        pump()
    }

    private func filterRegularFiles(_ urls: [URL], maxBytes: Int64 = 512 * 1024 * 1024,
                                    limit: Int = 20) -> [(url: URL, size: Int64, mtime: TimeInterval)] {
        let fm = FileManager.default
        var valid: [(url: URL, size: Int64, mtime: TimeInterval)] = []
        for rawURL in urls.prefix(limit) {
            let url = (rawURL as NSURL).filePathURL ?? rawURL
            guard url.isFileURL,
                  let attrs = try? fm.attributesOfItem(atPath: url.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let size = (attrs[.size] as? NSNumber)?.int64Value,
                  size >= 0, size <= maxBytes else { continue }
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            valid.append((url, size, mtime))
        }
        return valid
    }

    func sendFilesToWindows(_ urls: [URL], destination: String?, setClipboard: Bool = true,
                            silent: Bool = false, cleanupDir: URL? = nil) {
        guard linked, receiverSupportsFiles, let transfer = fileTransfer else {
            if let cleanupDir { try? FileManager.default.removeItem(at: cleanupDir) }
            return
        }
        let items = filterRegularFiles(urls)
        guard items.count == urls.prefix(20).count, !items.isEmpty else {
            if let cleanupDir { try? FileManager.default.removeItem(at: cleanupDir) }
            if !silent {
                fileDropBar.showStatus("Можно отправлять только файлы и папки до 512 МБ",
                                       on: builtInScreen(), duration: 2.8)
            }
            return
        }
        let dest = destination ?? "downloads"
        let batchID = UUID().uuidString
        let label = items.count == 1 ? items[0].url.lastPathComponent : "\(items.count) файлов"
        if !silent {
            fileDropBar.showProgress("Отправляем на Windows: \(label)…", fraction: 0.03, on: builtInScreen())
        }
        uploadBatch(items, using: transfer, destination: dest,
                    setClipboard: setClipboard, batchID: batchID, onProgress: { [weak self] done, total, speed in
            guard let self, !silent else { return }
            let pct = Int((Double(done) / Double(max(1, total)) * 100.0).rounded())
            let speedStr = FileTransfer.formatSpeed(speed)
            let suffix = speedStr.isEmpty ? "\(pct) %" : "\(pct) % · \(speedStr)"
            self.fileDropBar.showProgress("Отправляем: \(label) · \(suffix)",
                                          fraction: Double(done) / Double(max(1, total)),
                                          on: self.builtInScreen())
        }) { [weak self] uploaded, firstError in
            if let cleanupDir { try? FileManager.default.removeItem(at: cleanupDir) }
            guard let self else { return }
            if !uploaded.isEmpty {
                self.log.record("uploaded \(uploaded.count) file(s) dest=\(dest)")
                if !silent {
                    let text = uploaded.count == 1
                        ? "✓ Отправлено на Windows в «Загрузки»: \(uploaded[0])"
                        : "✓ Отправлено на Windows в «Загрузки»: \(uploaded.count) файлов"
                    self.fileDropBar.showStatus(text, on: self.builtInScreen(), duration: 4.0)
                }
            } else if let firstError {
                self.log.record("file upload failed: \(firstError.localizedDescription)")
                if !silent {
                    self.fileDropBar.showStatus("Ошибка отправки: \(firstError.localizedDescription)",
                                                on: self.builtInScreen(), duration: 3.5)
                }
            }
        }
    }

    private func uploadBatch(_ items: [(url: URL, size: Int64, mtime: TimeInterval)], using transfer: FileTransfer,
                             destination: String, setClipboard: Bool, batchID: String,
                             onProgress: @escaping (Int64, Int64, Double) -> Void,
                             completion: @escaping ([String], Error?) -> Void) {
        let totalExpected = max(Int64(1), items.reduce(Int64(0)) { $0 + max(0, $1.size) })
        let start = Date()
        var perFileBytes = [Int64](repeating: 0, count: items.count)
        var uploadedNames = [String?](repeating: nil, count: items.count)
        var firstError: Error?
        var nextIndex = 0
        var active = 0
        let maxConcurrent = min(3, items.count)
        var lastHUDUpdate = Date.distantPast

        func emitProgress(force: Bool = false) {
            let now = Date()
            guard force || now.timeIntervalSince(lastHUDUpdate) >= 0.08 else { return }
            lastHUDUpdate = now
            let done = perFileBytes.reduce(Int64(0), +)
            let elapsed = max(0.05, now.timeIntervalSince(start))
            onProgress(done, totalExpected, Double(done) / elapsed)
        }

        func pump() {
            while active < maxConcurrent && nextIndex < items.count {
                let idx = nextIndex
                nextIndex += 1
                active += 1
                let item = items[idx]
                transfer.upload(fileURL: item.url, destination: destination,
                                setClipboard: setClipboard, batchID: batchID, onProgress: { sent, _ in
                    perFileBytes[idx] = min(max(0, item.size), sent)
                    emitProgress()
                }) { result in
                    switch result {
                    case .success(let savedName):
                        perFileBytes[idx] = max(0, item.size)
                        uploadedNames[idx] = savedName
                    case .failure(let error):
                        if firstError == nil { firstError = error }
                    }
                    active -= 1
                    emitProgress(force: true)
                    if active == 0 && nextIndex >= items.count {
                        completion(uploadedNames.compactMap { $0 }, firstError)
                    } else {
                        pump()
                    }
                }
            }
        }
        pump()
    }

    private func receivedClipboardCacheDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Prilo/Received", isDirectory: true)
    }

    private func pruneOldReceivedFiles(in directory: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                         options: [.skipsHiddenFiles]) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for item in contents {
            if let values = try? item.resourceValues(forKeys: [.contentModificationDateKey]),
               let modified = values.contentModificationDate, modified < cutoff {
                try? fm.removeItem(at: item)
            }
        }
    }

    func handleRemoteFileOffer(_ files: [OfferedFile]) {
        offerGeneration &+= 1
        let generation = offerGeneration
        offeredWindowsFiles = files
        refreshFileMenuItems()
        guard controlSettings.clipboardSync, controlSettings.clipboardFileSync,
              receiverSupportsFiles, let transfer = fileTransfer else { return }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > 0 else { return }
        // Only auto-prefetch tiny clipboard files (<= 2 MB) while cursor is on Mac so Wi-Fi stays free.
        guard !remote, total <= 2 * 1024 * 1024 else {
            if let first = files.first, total > 2 * 1024 * 1024 {
                fileDropBar.showStatus("С Windows доступен файл \(first.name) (\(FileTransfer.formatBytes(total))) — скачайте из меню",
                                       on: builtInScreen(), duration: 3.0)
            }
            return
        }
        let cacheDir = receivedClipboardCacheDirectory()
        pruneOldReceivedFiles(in: cacheDir)
        downloadBatch(files, using: transfer, into: cacheDir, onProgress: { _, _, _ in }) { [weak self] saved, _ in
            guard let self, self.linked, self.offerGeneration == generation, !saved.isEmpty else { return }
            let items = self.filterRegularFiles(saved, maxBytes: 25 * 1024 * 1024)
            let meta = items.map { "\($0.url.path)|\($0.size)|\($0.mtime)" }.sorted().joined(separator: "\n")
            self.lastSyncedClipboardHash = self.clipboardHash(kind: "files", payload: Data(meta.utf8))
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(saved as [NSURL])
            self.lastClipboardChangeCount = pb.changeCount
            self.log.record("synced \(saved.count) file(s) from Windows clipboard")
        }
    }

    func handleRemoteFileDrop(_ files: [OfferedFile]) {
        offerGeneration &+= 1
        offeredWindowsFiles = files
        refreshFileMenuItems()
        guard receiverSupportsFiles, let transfer = fileTransfer else { return }
        let fm = FileManager.default
        let targetDir = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        transferBatchFromWindows(files, using: transfer, into: targetDir, logPrefix: "received", writeClipboard: true)
    }

    private func transferBatchFromWindows(_ files: [OfferedFile], using transfer: FileTransfer, into targetDir: URL,
                                          logPrefix: String, writeClipboard: Bool = false) {
        let label = files.count == 1 ? files[0].name : "\(files.count) файлов"
        fileDropBar.showProgress("Получаем с Windows: \(label)…", fraction: 0.03, on: builtInScreen())
        downloadBatch(files, using: transfer, into: targetDir, onProgress: { [weak self] done, total, speed in
            guard let self else { return }
            let pct = Int((Double(done) / Double(max(1, total)) * 100.0).rounded())
            let speedStr = FileTransfer.formatSpeed(speed)
            let suffix = speedStr.isEmpty ? "\(pct) %" : "\(pct) % · \(speedStr)"
            self.fileDropBar.showProgress("Получаем: \(label) · \(suffix)",
                                          fraction: Double(done) / Double(max(1, total)),
                                          on: self.builtInScreen())
        }) { [weak self] saved, firstError in
            guard let self else { return }
            if !saved.isEmpty {
                if writeClipboard {
                    let items = self.filterRegularFiles(saved, maxBytes: 25 * 1024 * 1024)
                    if !items.isEmpty {
                        let meta = items.map { "\($0.url.path)|\($0.size)|\($0.mtime)" }.sorted().joined(separator: "\n")
                        self.lastSyncedClipboardHash = self.clipboardHash(kind: "files", payload: Data(meta.utf8))
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.writeObjects(saved as [NSURL])
                        self.lastClipboardChangeCount = pb.changeCount
                    }
                }
                self.lastReceivedFiles = saved
                self.showLastReceivedItem.title = saved.count == 1
                    ? "Показать в Finder: \(saved[0].lastPathComponent)"
                    : "Показать в Finder (\(saved.count) файлов)"
                self.showLastReceivedItem.isHidden = false
                let text = saved.count == 1
                    ? "✓ В «Загрузки»: \(saved[0].lastPathComponent) · Показать"
                    : "✓ В «Загрузки»: \(saved.count) файлов · Показать"
                self.fileDropBar.showStatus(text, on: self.builtInScreen(), duration: 6.0, revealURLs: saved)
                self.log.record("\(logPrefix) \(saved.count) file(s) from Windows")
            } else if let firstError {
                self.fileDropBar.showStatus("Ошибка получения файла: \(firstError.localizedDescription)",
                                            on: self.builtInScreen(), duration: 3.5)
            }
        }
    }

    func updateControlStatus() {
        if remote {
            display(.remote)
        } else if paused {
            display(.paused)
        } else if ready {
            display(.ready)
        } else if inputState == true {
            display(.inputUnavailable)
        } else {
            display(.needsPermission)
        }
    }

    func tick() {
        let now = Date()
        if let retryAt, now >= retryAt, connection == nil, releasing == nil {
            self.retryAt = nil
            if let reconnect, controlSettings.autoConnect { beginConnection(reconnect) }
        }
        channel?.heartbeat(now: now, capturing: remote)
        if remote, (!NSApp.isActive || !cursorHidden || !cursorDetached), now.timeIntervalSince(lastActivateAttempt) >= 0.15 {
            lastActivateAttempt = now
            if !NSApp.isActive {
                showCaptureAnchor()
                NSApp.activate(ignoringOtherApps: true)
            }
            if !cursorDetached || !NSApp.isActive {
                reinforceRemoteCursor()
            } else {
                updateRemoteCursor()
            }
        }
        if remote, !secureInputWarned, IsSecureEventInputEnabled() {
            warnSecureInput()
        }
        if !remote, now.timeIntervalSince(lastInputCheck) >= ((window.isVisible || !ready) ? 1.0 : 5.0) {
            lastInputCheck = now
            if window.isVisible || linked { refreshPermissions() }
            syncAwakeIfNeeded()
        }
        if linked, !remote, now.timeIntervalSince(lastClipboardCheck) >= 0.25 {
            lastClipboardCheck = now
            syncLocalClipboardIfNeeded()
        }
        flush()
    }

    func syncLocalClipboardIfNeeded() {
        guard linked, receiverSupportsSync, controlSettings.clipboardSync, let channel, channel.ready else { return }
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = count

        if receiverSupportsFiles && controlSettings.clipboardFileSync,
           let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let fileURLs = urls.compactMap { ($0 as NSURL).filePathURL ?? ($0.isFileURL ? $0 : nil) }
            let valid = filterRegularFiles(fileURLs, maxBytes: 25 * 1024 * 1024)
            let totalSize = valid.reduce(Int64(0)) { $0 + $1.size }
            guard valid.count == fileURLs.prefix(20).count, !valid.isEmpty, totalSize <= 25 * 1024 * 1024 else {
                lastSyncedClipboardHash = nil
                return
            }
            let meta = valid.map { "\($0.url.path)|\($0.size)|\($0.mtime)" }.sorted().joined(separator: "\n")
            let digest = clipboardHash(kind: "files", payload: Data(meta.utf8))
            guard digest != lastSyncedClipboardHash else { return }
            lastSyncedClipboardHash = digest
            sendFilesToWindows(valid.map(\.url), destination: "clipboard", setClipboard: true, silent: true)
            let label = valid.count == 1 ? valid[0].url.lastPathComponent : "\(valid.count) файлов"
            fileDropBar.showStatus("✓ В буфер Windows: \(label)", on: builtInScreen(), duration: 1.8)
            return
        }

        if let raw = pb.string(forType: .string) {
            let normalized = normalizeClipboardText(raw)
            guard !normalized.isEmpty, normalized.utf8.count <= maxClipboardBytes else { return }
            let digest = clipboardHash(kind: "text", payload: Data(normalized.utf8))
            guard digest != lastSyncedClipboardHash else { return }
            lastSyncedClipboardHash = digest
            channel.sendClipboard(normalized)
            return
        }

        let rawPNG = pb.data(forType: .png)
        let rawTIFF = rawPNG == nil ? pb.data(forType: .tiff) : nil
        guard rawPNG != nil || rawTIFF != nil else {
            lastSyncedClipboardHash = nil
            return
        }
        clipboardQueue.async { [weak self, weak channel] in
            guard let self else { return }
            let pngData: Data?
            if let rawPNG {
                pngData = rawPNG
            } else if let rawTIFF, let rep = NSBitmapImageRep(data: rawTIFF) {
                pngData = rep.representation(using: .png, properties: [:])
            } else {
                pngData = nil
            }
            guard let pngData, !pngData.isEmpty, pngData.count <= maxClipboardImageBytes else {
                DispatchQueue.main.async { self.lastSyncedClipboardHash = nil }
                return
            }
            let digest = self.clipboardHash(kind: "image", payload: pngData)
            DispatchQueue.main.async {
                guard let channel, channel.ready, self.channel === channel,
                      digest != self.lastSyncedClipboardHash else { return }
                self.lastSyncedClipboardHash = digest
                channel.sendClipboardImage(pngData)
            }
        }
    }

    func applyRemoteClipboard(_ text: String) {
        guard controlSettings.clipboardSync else { return }
        let normalized = normalizeClipboardText(text)
        guard !normalized.isEmpty, normalized.utf8.count <= maxClipboardBytes else { return }
        lastSyncedClipboardHash = clipboardHash(kind: "text", payload: Data(normalized.utf8))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(normalized, forType: .string)
        lastClipboardChangeCount = pb.changeCount
    }

    func applyRemoteClipboardImage(_ base64: String) {
        guard controlSettings.clipboardSync,
              let pngData = Data(base64Encoded: base64),
              !pngData.isEmpty, pngData.count <= maxClipboardImageBytes,
              let image = NSImage(data: pngData) else { return }
        lastSyncedClipboardHash = clipboardHash(kind: "image", payload: pngData)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(pngData, forType: .png)
        if let tiff = image.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        lastClipboardChangeCount = pb.changeCount
    }

    private func clipboardHash(kind: String, payload: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(kind.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: payload)
        return Data(hasher.finalize())
    }

    func installTap() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let baseMask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<PriloApp>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: baseMask,
                                           callback: callback, userInfo: userInfo) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        tap = port
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        let gestureMask = Self.gestureEventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << UInt64($1)) }
        var gestureMode = "session-only"
        for (location, mode) in [(CGEventTapLocation.cghidEventTap, "session+hid-gestures"),
                                 (CGEventTapLocation.cgSessionEventTap, "session+session-gestures")] {
            if let gPort = CGEvent.tapCreate(tap: location, place: .headInsertEventTap,
                                             options: .defaultTap, eventsOfInterest: gestureMask,
                                             callback: callback, userInfo: userInfo) {
                let gSource = CFMachPortCreateRunLoopSource(nil, gPort, 0)
                gestureTap = gPort
                gestureTapSource = gSource
                CFRunLoopAddSource(CFRunLoopGetMain(), gSource, .commonModes)
                CGEvent.tapEnable(tap: gPort, enable: true)
                gestureMode = mode
                break
            }
        }
        log.record("input tap mode=\(gestureMode)")
        return true
    }

    func removeTap() {
        if let source = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        tapSource = nil
        if let source = gestureTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let gestureTap { CFMachPortInvalidate(gestureTap) }
        gestureTap = nil
        gestureTapSource = nil
    }

    func stop() {
        leave(reason: "disconnect")
        channel?.close()
        channel = nil
        fileTransfer?.invalidate()
        fileTransfer = nil
        connection = nil
        linked = false
        paused = false
        ready = false
        sending = false
        receiverSupportsShortcuts = false
        receiverSupportsFiles = false
        receiverSupportsSync = false
        offeredWindowsFiles.removeAll()
        cachedTransferredFiles.removeAll()
        suppressedShortcutKeys.removeAll()
        fileDropBar.hide()
        if let act = latencyActivity {
            ProcessInfo.processInfo.endActivity(act)
            latencyActivity = nil
        }
        topEdgePush.reset()
        pinchDetector.reset()
        lastSentAwake = nil
        pending.removeAll()
        localButtons.removeAll()
        localKeys.removeAll()
        removeTap()
        refreshFileMenuItems()
    }

    func stopAndRelease() {
        let needsRelease = channel == nil && (remote || pending.first?.kind == "release" || (linked && sending))
        let lastConnection = connection
        stop()
        guard needsRelease, let lastConnection else {
            display(.idle)
            return
        }
        releasing = lastConnection
        display(.disconnecting)
        lastConnection.releaseWhenIdle { [weak self, weak lastConnection] in
            guard let self, let lastConnection, self.releasing === lastConnection else { return }
            self.releasing = nil
            self.display(.idle)
            self.finishQuit()
        }
    }

    @objc func disconnect() {
        guard releasing == nil else { return }
        log.record("disconnect requested")
        cancelAutomaticConnection()
        stopAndRelease()
    }

    @objc func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        cancelAutomaticConnection()
        if releasing == nil { stopAndRelease() }
        guard releasing != nil else { return .terminateNow }
        quitting = true
        // The receiver's watchdog releases held keys if the last request cannot arrive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.finishQuit() }
        return .terminateLater
    }

    func finishQuit() {
        guard quitting else { return }
        quitting = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        stop()
        log.record("shutdown")
        log.drain()
    }

    func leave(reason: String) {
        guard remote else { return }
        remote = false
        topEdgePush.reset()
        swipeDetector.reset()
        pinchDetector.reset()
        suppressedShortcutKeys.removeAll()
        if handoffConfirmed && controlSettings.animate { cue.show(at: entry, entering: false) }
        handoffConfirmed = false
        pending = [Input(kind: "release")]
        flushIfIdle()
        captureAnchor?.orderOut(nil)
        CGAssociateMouseAndMouseCursorPosition(1)
        if cursorHidden { CGDisplayShowCursor(CGMainDisplayID()) }
        cursorDetached = false
        cursorHidden = false
        CGWarpMouseCursorPosition(CGPoint(x: entry.x, y: entry.y + 8))
        previousApp?.activate(options: [])
        previousApp = nil
        log.record("control returned to Mac reason=\(reason)")
        if channel != nil {
            log.record("stream capture frames=\(captureFrames) keys=\(captureKeyEvents) peakQueue=\(capturePeakQueue) peakWriteUs=\(capturePeakWrite / 1000)")
        }
        updateControlStatus()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if window != nil { refreshPermissions() }
        updateRemoteCursor()
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard remote else { return }
        cursorDetached = false
        reinforceRemoteCursor()
    }

    func enableBackgroundCursorControl() -> Bool {
        typealias DefaultConnFn = @convention(c) () -> Int32
        typealias SetPropFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> CGError
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connSym = dlsym(rtldDefault, "_CGSDefaultConnection"),
              let propSym = dlsym(rtldDefault, "CGSSetConnectionProperty") else {
            return false
        }
        let cid = unsafeBitCast(connSym, to: DefaultConnFn.self)()
        let setProp = unsafeBitCast(propSym, to: SetPropFn.self)
        return setProp(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == .success
    }

    func warnSecureInput() {
        guard !secureInputWarned else { return }
        secureInputWarned = true
        log.record("warning: macOS Secure Event Input is active — keyboard events blocked")
        fileDropBar.showStatus("⚠ macOS блокирует клавиатуру (активно поле пароля или Secure Input)",
                               on: builtInScreen(), duration: 5.5)
    }

    func showCaptureAnchor() {
        if captureAnchor == nil {
            let panel = CaptureKeyPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.alphaValue = 0.01
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            captureAnchor = panel
        }
        if let main = NSScreen.screens.first {
            let origin = NSPoint(x: capturedBounds.midX, y: main.frame.maxY - capturedBounds.midY)
            captureAnchor?.setFrameOrigin(origin)
        }
        captureAnchor?.makeKeyAndOrderFront(nil)
    }

    func reinforceRemoteCursor() {
        guard remote else { return }
        cursorDetached = CGAssociateMouseAndMouseCursorPosition(0) == .success
        if cursorHidden {
            CGDisplayShowCursor(CGMainDisplayID())
            cursorHidden = false
        }
        if backgroundCursorEnabled || NSApp.isActive {
            cursorHidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
        }
    }

    func updateRemoteCursor() {
        guard remote else { return }
        if !cursorDetached {
            cursorDetached = CGAssociateMouseAndMouseCursorPosition(0) == .success
        }
        guard backgroundCursorEnabled || NSApp.isActive else { return }
        if !cursorHidden { cursorHidden = CGDisplayHideCursor(CGMainDisplayID()) == .success }
    }

    func warpForCapture() {
        CGWarpMouseCursorPosition(CGPoint(x: floor(capturedBounds.midX), y: floor(capturedBounds.midY)))
        lastWarp = Date()
    }

    func enqueueMotion(x: Int32, y: Int32) {
        let movement = pointer.scale(x: x, y: y)
        guard movement.x != 0 || movement.y != 0 else { return }
        if let last = pending.indices.last, pending[last].kind == "move" {
            pending[last].x = min(10000, max(-10000, pending[last].x + movement.x))
            pending[last].y = min(10000, max(-10000, pending[last].y + movement.y))
        } else {
            pending.append(Input(kind: "move", x: movement.x, y: movement.y))
        }
    }

    func enqueueScroll(x: Double, y: Double, continuous: Bool) {
        let delta = scrollMotion.scale(x: x, y: y, continuous: continuous)
        guard delta.x != 0 || delta.y != 0 else { return }
        if let last = pending.indices.last, pending[last].kind == "scroll" {
            pending[last].x = min(10000, max(-10000, pending[last].x + delta.x))
            pending[last].y = min(10000, max(-10000, pending[last].y + delta.y))
        } else {
            pending.append(Input(kind: "scroll", x: delta.x, y: delta.y))
        }
    }

    func flushIfIdle() {
        if !pending.isEmpty && !sending {
            flush()
        }
    }

    func flushMotionIfDue() {
        if !pending.isEmpty && !sending && Date().timeIntervalSince(lastSend) >= 0.006 {
            flush()
        }
    }

    func flush() {
        guard let connection, linked, !sending,
              !pending.isEmpty || Date().timeIntervalSince(lastSend) > (remote ? 0.5 : 5) else { return }
        if remote { capturePeakQueue = max(capturePeakQueue, pending.count) }
        let batch = Array(pending.prefix(128))
        pending.removeFirst(batch.count)
        lastSend = Date()
        sending = true
        if let channel {
            let writingCapture = remote ? captureID : 0
            let writeStart = DispatchTime.now().uptimeNanoseconds
            channel.send(batch, capture: captureID) { [weak self, weak channel] in
                guard let self, let channel, self.channel === channel else { return }
                if self.remote && self.captureID == writingCapture {
                    self.captureFrames += 1
                    self.capturePeakWrite = max(self.capturePeakWrite, DispatchTime.now().uptimeNanoseconds - writeStart)
                }
                self.sending = false
                if !self.pending.isEmpty {
                    self.flush()
                }
            }
            return
        }
        connection.send(batch) { [weak self, weak connection] result in
            guard let self, let connection, self.connection === connection else { return }
            self.sending = false
            switch result {
            case .http(204):
                if self.remote && batch.first?.kind == "enter" {
                    self.handoffConfirmed = true
                    if self.controlSettings.animate { self.cue.show(at: self.entry, entering: true) }
                }
            case .http(200):
                self.leave(reason: "Windows edge")
            default:
                self.connectionFailed(result)
            }
        }
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let original = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log.record("input tap disabled type=\(type.rawValue)")
            leave(reason: "input tap disabled")
            localKeys.removeAll()
            localButtons.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if let gestureTap { CGEvent.tapEnable(tap: gestureTap, enable: true) }
            return original
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let dx = Int32(clamping: event.getIntegerValueField(.mouseEventDeltaX))
        let dy = Int32(clamping: event.getIntegerValueField(.mouseEventDeltaY))
        let button = UInt16(clamping: event.getIntegerValueField(.mouseEventButtonNumber))
        if !remote {
            if Self.gestureEventTypes.contains(type.rawValue) { return original }
            switch type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                localButtons.insert(button)
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                localButtons.remove(button)
            case .keyDown: localKeys.insert(key)
            case .keyUp: localKeys.remove(key)
            default: break
            }
            guard type == .mouseMoved else { return original }
            let heldModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
            guard ready, pending.isEmpty, localButtons.isEmpty, localKeys.isEmpty,
                  event.flags.intersection(heldModifiers).isEmpty else {
                topEdgePush.reset()
                return original
            }
            let bounds = CGDisplayBounds(CGGetOnlineBuiltInDisplay())
            let atTopEdge = bounds.width > 0 && event.location.y >= bounds.minY - 1 && event.location.y <= bounds.minY + 1 &&
                            event.location.x >= bounds.minX && event.location.x < bounds.maxX
            guard topEdgePush.advance(dx: dx, dy: dy, atTopEdge: atTopEdge, now: Date().timeIntervalSinceReferenceDate) else {
                return original
            }
            remote = true
            captureID &+= 1
            captureFrames = 0
            captureKeyEvents = 0
            secureInputWarned = false
            capturePeakQueue = 0
            capturePeakWrite = 0
            handoffConfirmed = false
            capturedBounds = bounds
            pointer = PointerMotion(speed: controlSettings.speed)
            scrollMotion = ScrollMotion(smoothness: controlSettings.scrollSmoothness)
            swipeDetector.reset()
            pinchDetector.reset()
            suppressedShortcutKeys.removeAll()
            keyboard = RemoteKeyboard(commandIsControl: controlSettings.commandIsControl,
                                      commandSpaceSwitchesLanguage: controlSettings.commandSpaceSwitchesLanguage,
                                      macShortcuts: controlSettings.macShortcuts)
            lastWarp = .distantPast
            lastActivateAttempt = .distantPast
            lastReinforce = .distantPast
            entry = CGPoint(x: event.location.x, y: bounds.minY)
            let frontmost = NSWorkspace.shared.frontmostApplication
            previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
            // Keep the setup window from being raised while providing an invisible activation anchor.
            showCaptureAnchor()
            window.orderOut(nil)
            NSApp.activate(ignoringOtherApps: true)
            if IsSecureEventInputEnabled() {
                warnSecureInput()
            }
            updateRemoteCursor()
            warpForCapture()
            log.record("control entered Windows")
            updateControlStatus()
            syncLocalClipboardIfNeeded()
            pending.append(Input(kind: "enter", x: entryPosition(x: entry.x, in: bounds)))
            flushIfIdle()
            return nil
        }
        if type == .keyDown, key == 53, event.flags.contains([.maskControl, .maskAlternate]) {
            leave(reason: "escape shortcut")
            return nil
        }
        if type == .keyDown, key == 37, controlSettings.commandLLocksWindows,
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
           event.flags.contains(.maskCommand),
           event.flags.intersection([.maskShift, .maskControl, .maskAlternate]).isEmpty {
            captureKeyEvents += 1
            lockWindows()
            return nil
        }
        if type == .keyUp, suppressedShortcutKeys.remove(key) != nil {
            captureKeyEvents += 1
            return nil
        }
        if type == .keyDown, (key == 21 || key == 23), controlSettings.macShortcuts,
           event.flags.contains([.maskCommand, .maskShift]),
           event.flags.intersection([.maskControl, .maskAlternate]).isEmpty {
            captureKeyEvents += 1
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                suppressedShortcutKeys.insert(key)
                let releases = keyboard.releaseAllModifiers()
                if !releases.isEmpty { pending.append(contentsOf: releases) }
                if receiverSupportsShortcuts {
                    flushIfIdle()
                    channel?.sendShortcut("snip", capture: captureID)
                    log.record("shortcut snip")
                } else {
                    pending.append(contentsOf: [
                        Input(kind: "key", code: 0x137, down: true),
                        Input(kind: "key", code: 0x137, down: false),
                    ])
                    flushIfIdle()
                }
            }
            return nil
        }
        if pending.count >= 512 {
            leave(reason: "input queue full")
            return nil
        }
        if type.rawValue == 29 {
            if let nsEvent = NSEvent(cgEvent: event), !nsEvent.touches(matching: .any, in: nil).isEmpty {
                let touches = nsEvent.touches(matching: .touching, in: nil)
                let count = touches.count
                let now = Date().timeIntervalSinceReferenceDate
                if controlSettings.pinchToZoom && receiverSupportsShortcuts {
                    let touchPoints = touches.map { (x: Double($0.normalizedPosition.x), y: Double($0.normalizedPosition.y)) }
                    if let action = pinchDetector.update(touches: touchPoints, now: now) {
                        channel?.sendShortcut(action, capture: captureID)
                        log.record("pinch -> \(action)")
                    }
                } else {
                    pinchDetector.reset()
                }
                let avgX = count > 0 ? touches.reduce(0.0) { $0 + $1.normalizedPosition.x } / Double(count) : 0
                let avgY = count > 0 ? touches.reduce(0.0) { $0 + $1.normalizedPosition.y } / Double(count) : 0
                if let direction = swipeDetector.update(touchCount: count, x: avgX, y: avgY, now: now) {
                    if receiverSupportsShortcuts {
                        if let action = swipeShortcutAction(direction: direction,
                                                            horizontalAction: controlSettings.threeFingerSwipeAction,
                                                            upEnabled: controlSettings.threeFingerSwipeUp,
                                                            downEnabled: controlSettings.threeFingerSwipeDown) {
                            channel?.sendShortcut(action, capture: captureID)
                            log.record("swipe \(direction) -> \(action)")
                        }
                    } else {
                        let sequence = swipeKeySequence(direction: direction,
                                                        horizontalAction: controlSettings.threeFingerSwipeAction,
                                                        upEnabled: controlSettings.threeFingerSwipeUp,
                                                        downEnabled: controlSettings.threeFingerSwipeDown)
                        if !sequence.isEmpty {
                            pending.append(contentsOf: sequence)
                            flushIfIdle()
                        }
                    }
                }
            }
            return nil
        }
        if Self.gestureEventTypes.contains(type.rawValue) {
            return nil
        }
        var immediateFlush = false
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let recentWarp = Date().timeIntervalSince(lastWarp) < 0.045
            // Quartz may report the displacement of a recenter as a mouse delta.
            if !recentWarp || max(abs(Int64(dx)), abs(Int64(dy))) < 120 {
                enqueueMotion(x: dx, y: dy)
            }
            let centerX = floor(capturedBounds.midX)
            let centerY = floor(capturedBounds.midY)
            if !recentWarp && (!cursorDetached || abs(event.location.x - centerX) > 24 || abs(event.location.y - centerY) > 24) {
                warpForCapture()
                let now = Date()
                if !cursorDetached || now.timeIntervalSince(lastReinforce) >= 0.25 {
                    lastReinforce = now
                    reinforceRemoteCursor()
                }
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if button <= 2 {
                let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
                pending.append(Input(kind: "button", code: button, down: down))
                immediateFlush = true
            }
        case .scrollWheel:
            if pinchDetector.shouldSuppressScroll(now: Date().timeIntervalSinceReferenceDate) {
                break
            }
            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let rawX: Double
            let rawY: Double
            if continuous {
                let ptX = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
                let ptY = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
                rawX = ptX != 0 ? ptX : event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) * 10.0
                rawY = ptY != 0 ? ptY : event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * 10.0
            } else {
                rawX = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
                rawY = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            }
            enqueueScroll(x: -rawX, y: rawY, continuous: continuous)
        case .keyDown, .keyUp, .flagsChanged:
            captureKeyEvents += 1
            let down = type == .flagsChanged ? event.flags.rawValue & (modifierMasks[key] ?? 0) != 0 : type == .keyDown
            pending.append(contentsOf: keyboard.events(for: key, down: down, flagsChanged: type == .flagsChanged))
            immediateFlush = true
        default: break
        }
        if immediateFlush {
            flushIfIdle()
        } else {
            flushMotionIfDue()
        }
        return nil
    }
}

func CGGetOnlineBuiltInDisplay() -> CGDirectDisplayID {
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    if CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success,
       let builtIn = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0 }) {
        return builtIn
    }
    return CGMainDisplayID()
}

let app = NSApplication.shared
let delegate = PriloApp()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
