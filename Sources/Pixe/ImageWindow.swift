import AppKit

private class PassthroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

class ImageWindow: NSWindow {
    private var infoBar: NSVisualEffectView!
    private var infoLabel: NSTextField!
    private var infoPanel: NSVisualEffectView!
    private var infoPanelLabel: NSTextField!

    init(contentView: NSView) {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let windowSize = NSSize(width: 800, height: 600)
        let windowOrigin = NSPoint(
            x: screenFrame.midX - windowSize.width / 2,
            y: screenFrame.midY - windowSize.height / 2
        )
        let contentRect = NSRect(origin: windowOrigin, size: windowSize)

        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.contentView = contentView
        self.backgroundColor = .black
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.appearance = NSAppearance(named: .darkAqua)
        self.minSize = NSSize(width: 320, height: 240)
        self.isReleasedWhenClosed = false

        setupInfoBar()
        setupInfoPanel()
    }

    private func setupInfoBar() {
        infoBar = PassthroughVisualEffectView(frame: NSRect(x: 0, y: 0, width: 800, height: 24))
        infoBar.material = .hudWindow
        infoBar.blendingMode = .withinWindow
        infoBar.state = .active
        infoBar.autoresizingMask = [.width, .maxYMargin]

        infoLabel = NSTextField(labelWithString: "")
        infoLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = NSColor(white: 0.8, alpha: 1.0)
        infoLabel.frame = NSRect(x: 10, y: 2, width: 780, height: 20)
        infoLabel.autoresizingMask = [.width]

        infoBar.addSubview(infoLabel)
        contentView?.addSubview(infoBar)
    }

    func updateTitle(filename: String, index: Int, total: Int) {
        self.title = "\(filename) [\(index + 1)/\(total)]"
    }

    func updateInfo(_ text: String) {
        infoLabel.stringValue = text
    }

    // MARK: - Info Panel

    private func setupInfoPanel() {
        infoPanel = PassthroughVisualEffectView(frame: .zero)
        infoPanel.material = .hudWindow
        infoPanel.blendingMode = .withinWindow
        infoPanel.state = .active
        infoPanel.wantsLayer = true
        infoPanel.layer?.cornerRadius = 8
        infoPanel.isHidden = true

        infoPanelLabel = NSTextField(wrappingLabelWithString: "")
        infoPanelLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        infoPanelLabel.textColor = NSColor(white: 0.85, alpha: 1.0)
        infoPanelLabel.isSelectable = false
        infoPanelLabel.drawsBackground = false
        infoPanelLabel.isBezeled = false
        infoPanelLabel.translatesAutoresizingMaskIntoConstraints = false

        infoPanel.addSubview(infoPanelLabel)
        infoPanel.translatesAutoresizingMaskIntoConstraints = false
        contentView?.addSubview(infoPanel)

        guard let cv = contentView else { return }
        NSLayoutConstraint.activate([
            infoPanelLabel.topAnchor.constraint(equalTo: infoPanel.topAnchor, constant: 10),
            infoPanelLabel.bottomAnchor.constraint(equalTo: infoPanel.bottomAnchor, constant: -10),
            infoPanelLabel.leadingAnchor.constraint(equalTo: infoPanel.leadingAnchor, constant: 12),
            infoPanelLabel.trailingAnchor.constraint(equalTo: infoPanel.trailingAnchor, constant: -12),

            infoPanel.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
            infoPanel.centerYAnchor.constraint(equalTo: cv.centerYAnchor),
            infoPanel.widthAnchor.constraint(equalToConstant: 300),
        ])
    }

    func showInfoPanel(_ text: String) {
        infoPanelLabel.stringValue = text
        infoPanel.isHidden = false
    }

    func hideInfoPanel() {
        infoPanel.isHidden = true
    }

    func toggleInfoPanel(_ text: String) {
        if infoPanel.isHidden {
            showInfoPanel(text)
        } else {
            hideInfoPanel()
        }
    }

    var isInfoPanelVisible: Bool {
        return !infoPanel.isHidden
    }
}
