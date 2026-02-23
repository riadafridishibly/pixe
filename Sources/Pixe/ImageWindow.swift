import AppKit

private class PassthroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

class ImageWindow: NSWindow {
    private var infoBar: NSVisualEffectView!
    private var infoLabel: NSTextField!

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
        self.titleVisibility = .visible
        self.appearance = NSAppearance(named: .darkAqua)
        self.minSize = NSSize(width: 320, height: 240)
        self.isReleasedWhenClosed = false

        setupInfoBar()
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
}
