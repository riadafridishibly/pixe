import AppKit

class ImageWindow: NSWindow {
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
    }

    func updateTitle(filename: String, index: Int, total: Int) {
        self.title = "\(filename) [\(index + 1)/\(total)]"
    }
}
