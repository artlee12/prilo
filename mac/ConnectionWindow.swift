import AppKit
import SwiftUI

/// Sidebar destinations of the main window.
enum Pane: Hashable {
    case pc(UUID)
    case newPC
    case settings
}

/// Text fields of the connection form, used to move focus to the field that failed validation.
enum FormField: Hashable {
    case name, address, code, fingerprint
}

/// State shared between the app controller (PriloApp) and the SwiftUI window.
final class WindowModel: ObservableObject {
    @Published var state: ConnectionWindow.State = .idle
    @Published var profiles: [PCProfile] = []
    @Published var profileID: UUID? {
        didSet { if profileID != oldValue { power.show(profileID) } }
    }
    @Published var pane: Pane = .newPC
    @Published var name = ""
    @Published var address = UserDefaults.standard.string(forKey: "address") ?? ""
    @Published var code = ""
    @Published var fingerprint = ""
    @Published var notice = ""
    @Published var accessibility = false
    @Published var monitoring = false
    @Published var nearbyCount = 0
    @Published var focus: FormField?
    @Published var pairing: [NearbyPC]?
    @Published var confirmForget: PCProfile?
    @Published var renaming: PCProfile?
    @Published var settings = ControlSettings()

    weak var owner: PriloApp?
    let power: PowerModel
    let updates = UpdateModel()

    init(owner: PriloApp) {
        self.owner = owner
        power = PowerModel(profiles: owner.profiles)
        power.discoveredHost = { [weak owner] fingerprint in
            owner?.discovery.computers.first { $0.fingerprint == fingerprint }?.host
        }
    }

    var busy: Bool {
        switch state {
        case .connecting, .disconnecting: return true
        default: return false
        }
    }

    /// The form and the PC list can change only while no connection is active.
    var editing: Bool { !busy && !state.connected }

    var profile: PCProfile? { profiles.first { $0.id == profileID } }

    var connectionPane: Pane { profileID.map(Pane.pc) ?? .newPC }

    // MARK: Sidebar actions

    func select(_ next: Pane) {
        switch next {
        case .pc(let id):
            guard let target = profiles.first(where: { $0.id == id }) else { return }
            if editing && (target.id != profileID || pane != next) {
                owner?.selectProfile(target)
            } else if target.id == profileID {
                pane = next
            }
        case .newPC:
            newPC()
        case .settings:
            pane = next
        }
    }

    func newPC() {
        guard editing else { return }
        owner?.cancelAutomaticConnection()
        profileID = nil
        name = ""
        address = ""
        code = ""
        fingerprint = ""
        notice = ""
        pane = .newPC
        focus = .address
    }

    func startPairing() {
        guard editing, let owner else { return }
        owner.cancelAutomaticConnection()
        pane = connectionPane
        let peers = owner.discovery.computers
        guard !peers.isEmpty else {
            notice = "Пока ни одного ПК. Проверь, что новый приёмник запущен и Mac в той же сети. Если поиск блокируется, используй поля ручного подключения."
            return
        }
        pairing = peers
    }

    func pair(_ peer: NearbyPC, code text: String) {
        pairing = nil
        guard editing else { return }
        guard let invitation = PairingCode(text) else {
            notice = "Вставь код целиком из строки Fuso pairing code."
            return
        }
        owner?.pair(peer, code: invitation)
    }

    func rename(_ target: PCProfile, to text: String) {
        renaming = nil
        guard let renamed = owner?.renameProfile(target, to: text), renamed.id == profileID else { return }
        name = renamed.name
    }

    func forget(_ target: PCProfile) {
        confirmForget = nil
        guard editing, owner?.forgetProfile(target) == true else { return }
        newPC()
    }

    // MARK: Connection actions

    func primaryAction() {
        guard let owner else { return }
        if state.connected { owner.togglePause() } else { owner.connect() }
    }
}

final class ConnectionWindow: NSWindow {
    enum State {
        case idle, connecting, disconnecting, needsPermission, inputUnavailable, ready, remote, paused
        case error(String)

        var title: String {
            switch self {
            case .idle: return "Windows не подключён"
            case .connecting: return "Проверяем подключение…"
            case .disconnecting: return "Отключаем Windows…"
            case .needsPermission: return "Windows подключён · нужен доступ"
            case .inputUnavailable: return "Windows подключён · ввод недоступен"
            case .ready: return "Windows подключён · управление готово"
            case .remote: return "Мышь и клавиатура на Windows"
            case .paused: return "Управление приостановлено"
            case .error: return "Ошибка подключения"
            }
        }

        var detail: String {
            switch self {
            case .idle: return "Запусти Fuso Receiver на Windows и выбери «Найти ПК в сети». Код сопряжения есть в меню значка Fuso в трее Windows."
            case .connecting: return "Проверяем связь с приёмником, сертификат и код доступа."
            case .disconnecting: return "Завершаем передачу и отпускаем зажатые клавиши и кнопки."
            case .needsPermission: return "Связь с Windows есть. Чтобы управлять мышью и клавиатурой, включи доступ для Fuso ниже."
            case .inputUnavailable: return "Разрешение выдано, но macOS не дала перехватить ввод. Проверь «Мониторинг ввода», затем нажми «Проверить доступ»."
            case .ready: return "Веди курсор вверх за край MacBook. Вернуться можно через нижний край Windows или по Ctrl + Option + Esc."
            case .remote: return "Вернуться на Mac можно через нижний край Windows или по Ctrl + Option + Esc."
            case .paused: return "Курсор остаётся на Mac. Возобнови управление, когда оно понадобится."
            case .error(let message): return message
            }
        }

        var connected: Bool {
            switch self {
            case .needsPermission, .inputUnavailable, .ready, .remote, .paused: return true
            default: return false
            }
        }
    }

    struct Credentials {
        let id: UUID?
        let name: String
        let host: String
        let code: String
        let fingerprint: String

        func atHost(_ host: String) -> Self {
            Self(id: id, name: name, host: host, code: code, fingerprint: fingerprint)
        }
    }

    let model: WindowModel

    /// Status line under the form; the app controller writes errors here.
    var notice: String {
        get { model.notice }
        set { model.notice = newValue }
    }

    var inputMonitoring: Bool { model.monitoring }

    init(owner: PriloApp) {
        model = WindowModel(owner: owner)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        let hosting = NSHostingController(rootView: RootView(model: model))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.sizingOptions = [.minSize]
        contentViewController = hosting
        title = "Fuso"
        toolbarStyle = .unified
        isReleasedWhenClosed = false
        setContentSize(NSSize(width: 880, height: 640))
        setFrameAutosaveName("PriloMainWindow")
        if !setFrameUsingName("PriloMainWindow") { center() }
    }

    func setPermissions(accessibility: Bool, monitoring: Bool) {
        model.accessibility = accessibility
        model.monitoring = monitoring
    }

    func render(_ state: State) {
        model.state = state
        model.notice = ""
    }

    func credentials() -> Credentials? {
        makeFirstResponder(nil)
        let host = model.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = model.code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pin = model.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard octets.count == 4, octets.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && UInt8($0) != nil }),
              URL(string: "https://\(host):43821/input") != nil else {
            fail("Введи IPv4-адрес из пункта «Данные для ручного подключения» в трее Windows.", focus: .address)
            return nil
        }
        guard token.count == 32, token.unicodeScalars.allSatisfy(hex.contains) else {
            fail("Код доступа должен содержать 32 шестнадцатеричных символа.", focus: .code)
            return nil
        }
        guard pin.count == 64, pin.unicodeScalars.allSatisfy(hex.contains) else {
            fail("Отпечаток должен содержать 64 шестнадцатеричных символа.", focus: .fingerprint)
            return nil
        }
        let label = String(model.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        return Credentials(id: model.profileID, name: label, host: host, code: token, fingerprint: pin)
    }

    private func fail(_ message: String, focus: FormField) {
        model.pane = model.connectionPane
        model.notice = message
        model.focus = focus
    }

    func updateProfiles(_ items: [PCProfile], selected: PCProfile?) {
        model.profiles = items
        model.profileID = selected?.id
        if case .pc(let id) = model.pane, !items.contains(where: { $0.id == id }) {
            model.pane = model.connectionPane
        } else if model.pane == .newPC, let selected {
            model.pane = .pc(selected.id)
        }
        model.power.reload()
    }

    func loadProfile(_ selected: PCProfile, secrets: PCSecrets?) {
        model.profileID = selected.id
        model.name = selected.name
        model.address = selected.host
        model.code = secrets?.code ?? ""
        model.fingerprint = secrets?.fingerprint ?? ""
        model.pane = .pc(selected.id)
        model.notice = secrets == nil ? "Fuso не получил сохранённые ключи. Выбери этот ПК в боковой панели ещё раз. Если macOS спросит доступ к Связке ключей, нажми «Всегда разрешать»." : ""
    }

    func updateAddress(_ host: String) { model.address = host }

    func fillCredentials(_ credentials: Credentials) {
        model.profileID = model.profiles.first { $0.id == credentials.id }?.id
        model.name = credentials.name
        model.address = credentials.host
        model.code = credentials.code
        model.fingerprint = credentials.fingerprint
        model.pane = model.connectionPane
    }

    func updateNearby(_ count: Int) {
        if model.nearbyCount != count { model.nearbyCount = count }
    }
}
