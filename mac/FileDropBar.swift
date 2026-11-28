import AppKit

private let legacyFilenamesPasteboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

func extractDraggedFileURLs(from pb: NSPasteboard) -> [URL] {
    if let urls = pb.readObjects(forClasses: [NSURL.self],
                                 options: [.urlReadingFileURLsOnly: true]) as? [URL] {
        let resolved = urls.compactMap { ($0 as NSURL).filePathURL ?? ($0.isFileURL ? $0 : nil) }
        if !resolved.isEmpty {
            return resolved
        }
    }
    if let paths = pb.propertyList(forType: legacyFilenamesPasteboardType) as? [String] {
        return paths.map { URL(fileURLWithPath: $0) }
    }
    return []
}

final class FileDropBar {
    private var panel: NSPanel?
    private var contentView: StatusBannerView?
    private var label: NSTextField?
    private var progressTrack: NSView?
    private var progressFill: NSView?
    private var progressFillWidth: NSLayoutConstraint?
    private var labelCenterY: NSLayoutConstraint?
    private var materialView: NSVisualEffectView?
    private var glassCornerUpdater: ((CGFloat) -> Void)?
    private var dismissWork: DispatchWorkItem?
    private(set) var isShowingProgress = false

    private func ensurePanel() -> (NSPanel, StatusBannerView, NSTextField) {
        if let panel, let contentView, let label {
            return (panel, contentView, label)
        }
        let frame = NSRect(x: 0, y: 0, width: 450, height: 46)
        let next = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        next.isOpaque = false
        next.backgroundColor = .clear
        next.hasShadow = true
        next.ignoresMouseEvents = true
        next.hidesOnDeactivate = false
        next.level = .screenSaver
        next.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = StatusBannerView(frame: frame)

        let field = NSTextField(labelWithString: "")
        field.alignment = .center
        field.font = .systemFont(ofSize: 13.5, weight: .semibold)
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(field)

        let track = NSView()
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
        track.layer?.cornerRadius = 2
        track.isHidden = true
        track.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(track)

        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        fill.layer?.cornerRadius = 2
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)

        let centerY = field.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        let fillWidth = fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: 0.02)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            centerY,
            track.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            track.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            track.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -9),
            track.heightAnchor.constraint(equalToConstant: 4),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fillWidth,
        ])

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = 23
            glass.contentView = view
            next.contentView = glass
            next.hasShadow = false
            glassCornerUpdater = { [weak glass] radius in
                glass?.cornerRadius = radius
            }
        } else {
            let material = NSVisualEffectView(frame: frame)
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 23
            material.layer?.masksToBounds = true
            view.autoresizingMask = [.width, .height]
            material.addSubview(view)
            next.contentView = material
            materialView = material
        }

        self.panel = next
        self.contentView = view
        self.label = field
        self.progressTrack = track
        self.progressFill = fill
        self.progressFillWidth = fillWidth
        self.labelCenterY = centerY
        return (next, view, field)
    }

    private func applyCornerRadius(_ radius: CGFloat, view: StatusBannerView) {
        view.layer?.cornerRadius = radius
        glassCornerUpdater?(radius)
        materialView?.layer?.cornerRadius = radius
    }

    private func updateProgressBar(visible: Bool, fraction: Double) {
        progressTrack?.isHidden = !visible
        labelCenterY?.constant = visible ? -6 : 0
        guard visible, let track = progressTrack, let fill = progressFill else { return }
        if let old = progressFillWidth {
            old.isActive = false
        }
        let clamped = CGFloat(min(1.0, max(0.02, fraction.isFinite ? fraction : 0.02)))
        let next = fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: clamped)
        next.isActive = true
        progressFillWidth = next
    }

    func showProgress(_ message: String, fraction: Double, on screen: NSScreen? = nil) {
        guard let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let (panel, view, field) = ensurePanel()
        dismissWork?.cancel()
        isShowingProgress = true
        panel.ignoresMouseEvents = true
        view.onClick = nil
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingMiddle
        field.stringValue = message
        updateProgressBar(visible: true, fraction: fraction)
        applyCornerRadius(24, view: view)
        let width: CGFloat = 460
        let height: CGFloat = 54
        let vf = targetScreen.visibleFrame
        let posX = vf.midX - width / 2
        let posY = vf.maxY - height - 10
        panel.setFrame(NSRect(x: posX, y: posY, width: width, height: height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in
            self?.isShowingProgress = false
            self?.updateProgressBar(visible: false, fraction: 0)
            self?.panel?.orderOut(nil)
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: work)
    }

    func showStatus(_ message: String, on screen: NSScreen? = nil,
                    duration: TimeInterval = 3.2, revealURLs: [URL]? = nil) {
        guard let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let (panel, view, field) = ensurePanel()
        dismissWork?.cancel()
        isShowingProgress = false
        updateProgressBar(visible: false, fraction: 0)
        if let revealURLs, !revealURLs.isEmpty {
            panel.ignoresMouseEvents = false
            view.onClick = { [weak self] in
                self?.dismissWork?.cancel()
                self?.panel?.orderOut(nil)
                NSWorkspace.shared.activateFileViewerSelecting(revealURLs)
            }
        } else {
            panel.ignoresMouseEvents = true
            view.onClick = nil
        }
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingMiddle
        field.stringValue = message
        applyCornerRadius(23, view: view)
        let width: CGFloat = 450
        let height: CGFloat = 46
        let vf = targetScreen.visibleFrame
        let posX = vf.midX - width / 2
        let posY = vf.maxY - height - 10
        panel.setFrame(NSRect(x: posX, y: posY, width: width, height: height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isShowingProgress else { return }
            self.contentView?.onClick = nil
            self.panel?.orderOut(nil)
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func showLayoutBadge(_ code: String, on screen: NSScreen? = nil) {
        guard !isShowingProgress,
              let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let (panel, view, field) = ensurePanel()
        dismissWork?.cancel()
        updateProgressBar(visible: false, fraction: 0)
        panel.ignoresMouseEvents = true
        view.onClick = nil
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        field.stringValue = "🌐 Windows: \(code)"
        applyCornerRadius(20, view: view)
        let width: CGFloat = 158
        let height: CGFloat = 40
        let vf = targetScreen.visibleFrame
        let posX = vf.midX - width / 2
        let posY = vf.maxY - height - 10
        panel.setFrame(NSRect(x: posX, y: posY, width: width, height: height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isShowingProgress else { return }
            self.panel?.orderOut(nil)
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15, execute: work)
    }

    func hide() {
        dismissWork?.cancel()
        isShowingProgress = false
        updateProgressBar(visible: false, fraction: 0)
        contentView?.onClick = nil
        panel?.orderOut(nil)
    }
}

private final class StatusBannerView: NSView {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 23
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseUp(with event: NSEvent) {
        if let onClick {
            onClick()
            return
        }
        super.mouseUp(with: event)
    }
}
