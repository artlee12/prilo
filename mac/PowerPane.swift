import AppKit
import SwiftUI

/// Power, Wake-on-LAN and VPN actions for the PC open in the main window.
final class PowerModel: ObservableObject {
    private let profiles: Profiles
    @Published private(set) var profile: PCProfile?
    @Published var mac = ""
    @Published var broadcast = "255.255.255.255"
    @Published var notice = ""
    @Published var vpnNotice = ""
    @Published private(set) var busy = false
    @Published private(set) var vpnBusy = false
    private var wakeWatch: (profileID: UUID, until: Date)?
    var discoveredHost: ((String) -> String?)?

    init(profiles: Profiles) {
        self.profiles = profiles
    }

    var canAct: Bool { profile != nil && !busy }

    /// Shows the given saved PC, or nothing for an unsaved one.
    func show(_ id: UUID?) {
        let next = profiles.items.first { $0.id == id }
        let changed = next?.id != profile?.id
        profile = next
        guard changed else { return }
        mac = next?.wakeMAC ?? ""
        broadcast = next?.wakeBroadcast ?? "255.255.255.255"
        wakeWatch = nil
        notice = ""
        vpnNotice = ""
    }

    /// Picks up saved changes (name, Wake-on-LAN) without clearing messages.
    func reload() {
        guard let old = profile else { return }
        let next = profiles.items.first { $0.id == old.id }
        // Follow values the receiver reported unless the user is editing them.
        if mac == (old.wakeMAC ?? "") { mac = next?.wakeMAC ?? "" }
        if broadcast == (old.wakeBroadcast ?? "255.255.255.255") { broadcast = next?.wakeBroadcast ?? "255.255.255.255" }
        profile = next
    }

    private func target() -> WakeTarget? {
        guard let wake = WakeTarget(mac: mac, broadcast: broadcast) else {
            notice = "Введи MAC и Broadcast одного адаптера из пункта «Данные для ручного подключения…» в трее Windows."
            return nil
        }
        return wake
    }

    private func access(for profile: PCProfile) -> PowerAccess? {
        do {
            if let secrets = try profiles.load(profile.id) { return powerAccess(for: profile, secrets: secrets) }
        } catch {
            Diagnostics.shared.record("power keychain load failed code=\((error as NSError).code)")
        }
        notice = "Данные ПК не прочитались из Связки ключей. Переподключи этот ПК."
        return nil
    }

    private func powerAccess(for profile: PCProfile, secrets: PCSecrets) -> PowerAccess {
        var target = profile
        if let host = discoveredHost?(secrets.fingerprint) { target.host = host }
        return PowerAccess(profile: target, secrets: secrets)
    }

    func saveWake() {
        guard let profile, let wake = target() else { return }
        do {
            if let saved = try profiles.updateWake(profile.id, mac: wake.mac, broadcast: wake.broadcast) {
                self.profile = saved
                mac = wake.mac
                notice = "Настройки Wake-on-LAN сохранены."
            }
        } catch {
            notice = "Не удалось сохранить настройки Wake-on-LAN."
        }
    }

    func wakePC() {
        guard let profile, let wake = target() else { return }
        let secrets = try? profiles.load(profile.id)
        wakeWatch = nil
        busy = true
        notice = "Отправляем Wake-on-LAN…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sent: Bool
            do {
                try wake.send()
                sent = true
            } catch {
                sent = false
            }
            Diagnostics.shared.record("power wake packet sent=\(sent)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                self.notice = sent ? "Пакет Wake-on-LAN отправлен." :
                    "Пакет не отправлен. Проверь Broadcast и доступ Prilo к локальной сети."
                if sent, let secrets, self.profile?.id == profile.id {
                    let until = Date().addingTimeInterval(45)
                    self.wakeWatch = (profile.id, until)
                    self.notice = "Пакет отправлен. Ждём, пока Windows загрузится и запустит приёмник…"
                    self.watchForWake(profile, secrets: secrets, until: until)
                }
            }
        }
    }

    private func watchForWake(_ profile: PCProfile, secrets: PCSecrets, until: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.wakeWatch?.until == until else { return }
            self.powerAccess(for: profile, secrets: secrets).request(lock: false) { [weak self] result in
                guard let self, self.wakeWatch?.until == until else { return }
                if case .http(204) = result {
                    self.wakeWatch = nil
                    self.notice = "ПК в сети, приёмник ответил."
                    Diagnostics.shared.record("power wake confirmed")
                } else if Date() >= until {
                    self.wakeWatch = nil
                    self.notice = "Приёмник пока не ответил. Проверь, запустился ли ПК и открыт ли Prilo Receiver."
                    Diagnostics.shared.record("power wake not confirmed")
                } else {
                    self.watchForWake(profile, secrets: secrets, until: until)
                }
            }
        }
    }

    func checkPC() { request(lock: false) }

    func lockPC() { request(lock: true) }

    private func request(lock: Bool) {
        guard let profile, let access = access(for: profile) else { return }
        wakeWatch = nil
        busy = true
        notice = lock ? "Блокируем Windows…" : "Проверяем приёмник…"
        access.request(lock: lock) { [weak self] result in
            Diagnostics.shared.record("power \(lock ? "lock" : "status") \(result.description)")
            guard let self else { return }
            self.busy = false
            switch result {
            case .http(202) where lock: self.notice = "Windows заблокирована."
            case .http(204) where !lock: self.notice = "ПК в сети, приёмник отвечает."
            case .http(404): self.notice = "Обнови приёмник Prilo на Windows."
            case .http(401): self.notice = "Код питания не подошёл. Переподключи ПК в Prilo."
            case .http(503): self.notice = "Windows отклонила блокировку. Проверь журнал приёмника."
            default: self.notice = result.unreachableHint ?? "Приёмник ответил неожиданно (\(result.description)). Проверь журнал приёмника."
            }
        }
    }

    func vpn(connect: Bool) {
        guard let profile, !vpnBusy, let access = access(for: profile) else { return }
        vpnBusy = true
        vpnNotice = connect ? "Включаем VPN на Windows…" : "Выключаем VPN на Windows…"
        access.vpn(connect: connect) { [weak self] result in
            Diagnostics.shared.record("vpn \(connect ? "on" : "off") \(result.description)")
            guard let self else { return }
            self.vpnBusy = false
            switch result {
            case .http(202):
                self.vpnNotice = connect
                    ? "Happ на Windows получил команду включить VPN. Состояние туннеля видно в Happ."
                    : "Happ на Windows получил команду выключить VPN."
            case .http(424): self.vpnNotice = "Happ не установлен на Windows. Установи Happ для Windows и выбери в нём профиль."
            case .http(429): self.vpnNotice = "Подожди секунду и повтори."
            case .http(404): self.vpnNotice = "Обнови приёмник Prilo на Windows до 0.10.1, чтобы управлять VPN."
            case .http(401): self.vpnNotice = "Код питания не подошёл. Переподключи ПК в Prilo."
            case .http(503): self.vpnNotice = "Windows не смогла передать команду Happ. Проверь журнал приёмника."
            default: self.vpnNotice = result.unreachableHint ?? "Приёмник ответил неожиданно (\(result.description)). Проверь журнал приёмника."
            }
        }
    }

    func copyHomeConfig() {
        guard let profile, let wake = target(), let access = access(for: profile) else { return }
        do {
            let config = try access.homebridgeConfig(wake: wake)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(config, forType: .string)
            notice = "Настройки скопированы. Вставь их в массив accessories в конфигурации Homebridge. В них есть код питания."
        } catch {
            notice = "Не удалось подготовить настройки Homebridge."
        }
    }
}

/// Power and Wake-on-LAN section shown on a saved PC's page.
struct PowerSections: View {
    @ObservedObject var model: PowerModel
    @State private var showWake = false

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Button {
                    model.wakePC()
                } label: {
                    Label("Включить", systemImage: "power")
                }
                .secondaryActionStyle()
                Button {
                    model.lockPC()
                } label: {
                    Label("Заблокировать", systemImage: "lock.fill")
                }
                .secondaryActionStyle()
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button {
                    model.checkPC()
                } label: {
                    Label("Проверить", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .disabled(!model.canAct)

            if !model.notice.isEmpty {
                Label(model.notice, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            ExpandRow(title: "Wake-on-LAN", isExpanded: $showWake)
            if showWake {
                Group {
                    PastableField(title: "MAC", prompt: "02:11:22:33:44:55", text: $model.mac)
                    PastableField(title: "Broadcast", prompt: "255.255.255.255", text: $model.broadcast)
                    HStack {
                        Button("Скопировать для Apple «Дома»") { model.copyHomeConfig() }
                        Spacer()
                        Button("Сохранить") { model.saveWake() }
                    }
                    Text("Prilo берёт MAC и Broadcast у приёмника при подключении. Для другого адаптера возьми значения из пункта «Данные для ручного подключения…» в трее Windows. Запуск из полного выключения зависит от BIOS и адаптера.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!model.canAct)
            }
        } header: {
            Text("Питание")
        }

        Section {
            HStack(spacing: 10) {
                Button {
                    model.vpn(connect: true)
                } label: {
                    Label("Включить VPN", systemImage: "lock.shield")
                }
                .secondaryActionStyle()
                Button {
                    model.vpn(connect: false)
                } label: {
                    Label("Выключить VPN", systemImage: "lock.open")
                }
                .secondaryActionStyle()
                Spacer()
                if model.vpnBusy { ProgressView().controlSize(.small) }
            }
            .disabled(model.profile == nil || model.vpnBusy)
            if !model.vpnNotice.isEmpty {
                Label(model.vpnNotice, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("VPN на Windows")
        } footer: {
            Text("Команда уходит в Happ на этом ПК и применяется к профилю, выбранному в Happ. Чтобы Prilo не терял связь с ПК, в Happ должен быть включён обход локальной сети.")
                .foregroundStyle(.secondary)
        }
    }
}
