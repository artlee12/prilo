import AppKit
import SwiftUI

// Main window UI. On macOS 26+ the split view sidebar, toolbar and prominent buttons pick up
// Liquid Glass automatically; earlier releases get the standard System Settings look.

struct RootView: View {
    @ObservedObject var model: WindowModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 300)
        } detail: {
            detail
                .frame(minWidth: 540, minHeight: 540)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.startPairing()
                } label: {
                    Label(model.nearbyCount == 0 ? "Найти ПК в сети" : "Найти ПК в сети (\(model.nearbyCount))",
                          systemImage: "dot.radiowaves.left.and.right")
                }
                .help("Сопряжение с ПК, на котором запущен Fuso Receiver")
                .disabled(!model.editing)
                Button {
                    model.newPC()
                } label: {
                    Label("Добавить ПК", systemImage: "plus")
                }
                .help("Ввести данные ПК вручную")
                .disabled(!model.editing)
            }
        }
        .sheet(isPresented: Binding(get: { model.pairing != nil }, set: { if !$0 { model.pairing = nil } })) {
            PairingSheet(peers: model.pairing ?? [], onCancel: { model.pairing = nil }, onPair: model.pair)
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.pane {
        case .pc, .newPC:
            ConnectionView(model: model)
        case .settings:
            SettingsView(model: model)
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var model: WindowModel

    var body: some View {
        List(selection: Binding<Pane?>(get: { model.pane }, set: { if let next = $0 { model.select(next) } })) {
            Section("Компьютеры") {
                ForEach(model.profiles, id: \.id) { pc in
                    PCRow(pc: pc, active: pc.id == model.profileID && model.state.connected, state: model.state)
                        .tag(Pane.pc(pc.id))
                        .selectionDisabled(!model.editing && pc.id != model.profileID)
                        .contextMenu {
                            Button("Переименовать…") { model.renaming = pc }
                            Divider()
                            Button("Забыть ПК…", role: .destructive) { model.confirmForget = pc }
                                .disabled(!model.editing)
                        }
                }
                Label("Новый ПК", systemImage: "plus.circle")
                    .tag(Pane.newPC)
                    .selectionDisabled(!model.editing)
            }
            Section("Fuso") {
                Label("Настройки", systemImage: "gearshape")
                    .badge(model.updates.available == nil ? nil : Text("1"))
                    .tag(Pane.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            StatusBadge(state: model.state)
                .padding(10)
        }
    }
}

private struct PCRow: View {
    let pc: PCProfile
    let active: Bool
    let state: ConnectionWindow.State

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(pc.name).lineLimit(1)
                Text(pc.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: "pc")
                .overlay(alignment: .bottomTrailing) {
                    if active {
                        Circle()
                            .fill(state.tint)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(.background, lineWidth: 1.5))
                            .offset(x: 3, y: 2)
                    }
                }
        }
        .accessibilityLabel("\(pc.name), \(pc.host)")
    }
}

private struct StatusBadge: View {
    let state: ConnectionWindow.State

    var body: some View {
        HStack(spacing: 8) {
            if state.busy {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(state.tint).frame(width: 8, height: 8)
            }
            Text(state.shortTitle)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCapsule()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Connection

private struct ConnectionView: View {
    @ObservedObject var model: WindowModel
    @FocusState private var focused: FormField?
    @State private var showDetails = false
    @State private var newName = ""

    private var saved: PCProfile? { model.pane == .newPC ? nil : model.profile }

    var body: some View {
        Form {
            Section {
                if let saved {
                    HStack(spacing: 10) {
                        Image(systemName: "pc")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(saved.name)
                                .font(.title2.weight(.semibold))
                                .lineLimit(1)
                            Text(saved.host)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer()
                        Button {
                            model.renaming = saved
                        } label: {
                            Label("Переименовать", systemImage: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Переименовать ПК")
                    }
                }
                StatusCard(model: model)
                if !model.notice.isEmpty {
                    Label(model.notice, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if saved != nil {
                PowerSections(model: model.power)
            }

            Section {
                if saved == nil {
                    TextField("Имя ПК", text: $model.name, prompt: Text("Например, Домашний ПК"))
                        .focused($focused, equals: .name)
                    connectionFields
                } else {
                    ExpandRow(title: "Адрес, код и отпечаток", isExpanded: $showDetails)
                    if showDetails { connectionFields }
                }
            } header: {
                Text(saved == nil ? "Новый ПК" : "Подключение")
            } footer: {
                if saved == nil {
                    Text("Значения есть в пункте «Данные для ручного подключения…» меню Fuso в трее Windows. Проще выбрать «Найти ПК в сети» и вставить одноразовый код.")
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!model.editing)

            Section {
                PermissionRow(title: "Универсальный доступ", symbol: "accessibility",
                              detail: "Нужен для управления мышью и клавиатурой.",
                              granted: model.accessibility) { model.owner?.openPrivacy() }
                PermissionRow(title: "Мониторинг ввода", symbol: "keyboard",
                              detail: "Нужен, если Fuso сообщает, что ввод недоступен.",
                              granted: model.monitoring) { model.owner?.openInputMonitoring() }
            } header: {
                HStack {
                    Text("Разрешения macOS")
                    Spacer()
                    Button("Проверить доступ") { model.owner?.recheckPermissions() }
                        .controlSize(.small)
                }
            }

            Section("Диагностика") {
                LabeledContent {
                    HStack {
                        Button("Скопировать") { model.owner?.copyDiagnostics() }
                        Button("Показать в Finder") { model.owner?.revealDiagnostics() }
                    }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Журнал")
                            Text("Без кодов, IP и нажатий клавиш")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                }
                HStack {
                    if let saved {
                        Button("Забыть «\(saved.name)»…", role: .destructive) { model.confirmForget = saved }
                            .disabled(!model.editing)
                    }
                    Spacer()
                    Button("Выйти из Fuso") { model.owner?.quit() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(saved?.name ?? "Новый ПК")
        .navigationSubtitle(model.state.shortTitle)
        .onChange(of: model.focus) { _, next in
            guard let next else { return }
            if saved != nil { showDetails = true }
            focused = next
            model.focus = nil
        }
        .onChange(of: model.renaming?.id) { _, _ in
            newName = model.renaming?.name ?? ""
        }
        .alert("Переименовать ПК",
               isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } }),
               presenting: model.renaming) { profile in
            TextField("Имя", text: $newName)
            Button("Сохранить") { model.rename(profile, to: newName) }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Отмена", role: .cancel) { model.renaming = nil }
        } message: { _ in
            Text("Имя видно только в Fuso на этом Mac.")
        }
        .confirmationDialog(model.confirmForget.map { "Забыть «\($0.name)»?" } ?? "",
                            isPresented: Binding(get: { model.confirmForget != nil },
                                                 set: { if !$0 { model.confirmForget = nil } }),
                            presenting: model.confirmForget) { profile in
            Button("Забыть ПК", role: .destructive) { model.forget(profile) }
            Button("Отмена", role: .cancel) { model.confirmForget = nil }
        } message: { _ in
            Text("Fuso удалит сохранённые данные для этого ПК. Его можно будет добавить заново.")
        }
    }

    @ViewBuilder private var connectionFields: some View {
        PastableField(title: "IP-адрес Windows", prompt: "192.168.1.20", text: $model.address)
            .focused($focused, equals: .address)
        PastableField(title: "Код доступа", prompt: "32 символа", text: $model.code, secure: true)
            .focused($focused, equals: .code)
        PastableField(title: "Отпечаток сертификата", prompt: "64 символа", text: $model.fingerprint)
            .focused($focused, equals: .fingerprint)
    }
}

private struct StatusCard: View {
    @ObservedObject var model: WindowModel

    var body: some View {
        let state = model.state
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(state.tint.opacity(0.16))
                    if state.busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: state.symbol)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(state.tint)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title)
                        .font(.title3.weight(.semibold))
                    Text(state.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Spacer()
                if !model.editing, !isDisconnecting {
                    Button(isConnecting ? "Отменить" : "Отключить Windows") { model.owner?.disconnect() }
                        .controlSize(.large)
                        .secondaryActionStyle()
                }
                Button(primaryTitle) { model.primaryAction() }
                    .controlSize(.large)
                    .prominentActionStyle()
                    .keyboardShortcut(model.editing ? .defaultAction : nil)
                    .disabled(model.busy)
            }
        }
        .padding(.vertical, 6)
        .animation(.smooth(duration: 0.25), value: state.title)
    }

    private var primaryTitle: String {
        if case .paused = model.state { return "Возобновить управление" }
        return model.state.connected ? "Приостановить управление" : "Подключить Windows"
    }

    private var isConnecting: Bool { if case .connecting = model.state { return true } else { return false } }
    private var isDisconnecting: Bool { if case .disconnecting = model.state { return true } else { return false } }
}

/// Labeled text field with a trailing paste button. Pasted text is trimmed.
struct PastableField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    var secure = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Group {
                    if secure {
                        SecureField(title, text: $text, prompt: Text(prompt))
                    } else {
                        TextField(title, text: $text, prompt: Text(prompt))
                    }
                }
                .labelsHidden()
                .font(.body.monospaced())
                .multilineTextAlignment(.trailing)
                Button {
                    if let value = NSPasteboard.general.string(forType: .string) {
                        text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .help("Вставить из буфера обмена")
                .accessibilityLabel("Вставить: \(title)")
            }
        }
    }
}

/// Row that shows or hides the rows below it in a grouped form.
struct ExpandRow: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? "Развёрнуто" : "Свёрнуто")
    }
}

private struct PermissionRow: View {
    let title: String
    let symbol: String
    let detail: String
    let granted: Bool
    let open: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Выдан", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Открыть настройки", action: open)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol)
            }
        }
    }
}

// MARK: - Pairing

private struct PairingSheet: View {
    let peers: [NearbyPC]
    let onCancel: () -> Void
    let onPair: (NearbyPC, String) -> Void
    @State private var index = 0
    @State private var code = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                Text("Сопряжение с Windows")
                    .font(.title2.weight(.semibold))
                Text("Выбери ПК и вставь код из пункта «Код сопряжения…» в меню Fuso в трее Windows. Если код истёк, выбери там «Новый код сопряжения».")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 24)

            Form {
                Picker("Компьютер", selection: $index) {
                    ForEach(peers.indices, id: \.self) { item in
                        Text("\(String(peers[item].name.prefix(38))) · \(peers[item].host)").tag(item)
                    }
                }
                PastableField(title: "Код", prompt: "XXXX-XXXX-XXXX-XXXX-123456", text: $code, secure: true)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 130)

            HStack {
                Spacer()
                Button("Отмена", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Сопрячь") {
                    if peers.indices.contains(index) { onPair(peers[index], code) }
                }
                .keyboardShortcut(.defaultAction)
                .prominentActionStyle()
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.large)
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @ObservedObject var model: WindowModel

    var body: some View {
        Form {
            UpdateSection(model: model.updates)
            Section("Подключение") {
                Toggle("Подключаться к последнему ПК при запуске", isOn: $model.settings.autoConnect)
            }
            Section("Переход") {
                Toggle("Показывать подсказку при переходе", isOn: $model.settings.animate)
            }
            Section("Буфер обмена") {
                Toggle("Общий буфер обмена (текст и скриншоты)", isOn: $model.settings.clipboardSync)
            }
            Section {
                Toggle("Быстрая передача файлов (Finder → «Отправить на Windows» и сброс с Windows)", isOn: $model.settings.fileTransferEnabled)
                Toggle("Файлы через буфер обмена Mac → Windows (⌘+C → Ctrl+V, до 25 МБ)", isOn: $model.settings.clipboardFileSync)
            } header: {
                Text("Передача файлов")
            } footer: {
                Text("Чтобы отправить файл или папку с MacBook, нажмите двумя пальцами по файлу в Finder → «Быстрые действия» (или «Службы») → «Отправить на Windows». Все файлы сохраняются в папку «Загрузки».")
                    .foregroundStyle(.secondary)
            }
            Section("Блокировка и экран") {
                Toggle("Не давать Windows гасить экран, пока активен Mac", isOn: $model.settings.keepWindowsAwake)
                Toggle("Блокировать Windows при блокировке Mac", isOn: $model.settings.lockWindowsOnMacLock)
            }
            Section("Жесты тачпада") {
                Picker("Свайп 3 пальцами влево / вправо", selection: $model.settings.threeFingerSwipeAction) {
                    Text("Рабочие столы Windows").tag(ThreeFingerSwipeAction.desktops)
                    Text("Переключение приложений (Alt + Tab)").tag(ThreeFingerSwipeAction.switchApps)
                    Text("Назад / Вперёд").tag(ThreeFingerSwipeAction.browserHistory)
                    Text("Выключено").tag(ThreeFingerSwipeAction.off)
                }
                Toggle("Свайп 3 пальцами вверх — обзор окон (Win + Tab)", isOn: $model.settings.threeFingerSwipeUp)
                Toggle("Свайп 3 пальцами вниз — свернуть окна (Win + D)", isOn: $model.settings.threeFingerSwipeDown)
                Toggle("Щипок двумя пальцами — масштаб (Ctrl + колёсико)", isOn: $model.settings.pinchToZoom)
            }
            Section {
                Toggle("⌘ Command работает как Ctrl", isOn: $model.settings.commandIsControl)
                Toggle("Привычные сочетания Mac (текст и скриншот ⌘+Shift+4/5 → Print Screen)", isOn: $model.settings.macShortcuts)
                Toggle("⌘ + Пробел переключает язык на Windows", isOn: $model.settings.commandSpaceSwitchesLanguage)
                Toggle("Показывать раскладку клавиатуры Windows (RU / EN)", isOn: $model.settings.showLayoutIndicator)
                Toggle("⌘ + L блокирует Windows", isOn: $model.settings.commandLLocksWindows)
                HStack {
                    Text("Курсор и прокрутка как на MacBook")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("По умолчанию") {
                        model.settings.speed = ControlSettings.defaultCursorSpeed
                        model.settings.scrollSmoothness = ControlSettings.defaultScrollSmoothness
                    }
                    .secondaryActionStyle()
                    .controlSize(.small)
                    .disabled(
                        abs(model.settings.speed - ControlSettings.defaultCursorSpeed) < 0.01 &&
                        abs(model.settings.scrollSmoothness - ControlSettings.defaultScrollSmoothness) < 0.01
                    )
                }
                LabeledContent("Скорость курсора Windows") {
                    HStack(spacing: 10) {
                        Image(systemName: "tortoise").foregroundStyle(.secondary)
                        Slider(value: $model.settings.speed, in: 0.2...2.0)
                            .frame(width: 180)
                            .accessibilityLabel("Скорость курсора Windows")
                        Image(systemName: "hare").foregroundStyle(.secondary)
                        Text("\(Int(model.settings.speed * 100)) %")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                LabeledContent("Плавность прокрутки") {
                    HStack(spacing: 10) {
                        Image(systemName: "tortoise").foregroundStyle(.secondary)
                        Slider(value: $model.settings.scrollSmoothness, in: 0.2...3.0)
                            .frame(width: 180)
                            .accessibilityLabel("Плавность прокрутки")
                        Image(systemName: "hare").foregroundStyle(.secondary)
                        Text("\(Int(model.settings.scrollSmoothness * 100)) %")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            } header: {
                Text("Мышь и клавиатура")
            } footer: {
                Text("Изменения применятся при следующем переходе курсора на Windows. При выключенном сопоставлении ⌘ работает как клавиша Windows.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .navigationTitle("Настройки")
    }
}

// MARK: - Styling helpers

extension ConnectionWindow.State {
    var busy: Bool {
        switch self {
        case .connecting, .disconnecting: return true
        default: return false
        }
    }

    var tint: Color {
        switch self {
        case .ready: return .green
        case .remote: return .blue
        case .paused, .needsPermission, .inputUnavailable: return .orange
        case .error: return .red
        case .connecting, .disconnecting: return .accentColor
        case .idle: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .remote: return "cursorarrow.motionlines"
        case .paused: return "pause.circle.fill"
        case .needsPermission, .inputUnavailable: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .connecting, .disconnecting, .idle: return "pc"
        }
    }

    /// Compact title for the sidebar badge and the window subtitle.
    var shortTitle: String {
        switch self {
        case .idle: return "Не подключён"
        case .connecting: return "Подключение…"
        case .disconnecting: return "Отключение…"
        case .needsPermission: return "Нужен доступ"
        case .inputUnavailable: return "Ввод недоступен"
        case .ready: return "Управление готово"
        case .remote: return "Ввод на Windows"
        case .paused: return "Приостановлено"
        case .error: return "Ошибка подключения"
        }
    }
}

extension View {
    @ViewBuilder func prominentActionStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder func secondaryActionStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }
}
