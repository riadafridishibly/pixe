import MetalKit

class MetalImageView: MTKView {
    var inputHandler: InputHandler!

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)

        self.isPaused = true
        self.enableSetNeedsDisplay = true
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)
        self.layer?.isOpaque = true
        (self.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)

        setupGestureRecognizers()
    }

    required init(coder: NSCoder) {
        fatalError("not implemented")
    }

    private func setupGestureRecognizers() {
        let magnification = NSMagnificationGestureRecognizer(
            target: self, action: #selector(handleMagnification(_:))
        )
        addGestureRecognizer(magnification)

        let pan = NSPanGestureRecognizer(
            target: self, action: #selector(handlePan(_:))
        )
        pan.numberOfTouchesRequired = 2
        addGestureRecognizer(pan)
    }

    // MARK: - Key Events

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        inputHandler?.handleKeyDown(event: event, view: self)
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let renderer = inputHandler?.renderer else { return }
        if renderer.mode == .image && renderer.scale > 1.0 {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    // MARK: - Scroll Wheel

    override func scrollWheel(with event: NSEvent) {
        inputHandler?.handleScrollWheel(event: event, view: self)
    }

    // MARK: - Gestures

    @objc private func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
        inputHandler?.handleMagnification(gesture: gesture, view: self)
    }

    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        inputHandler?.handlePan(gesture: gesture, view: self)
    }
}
