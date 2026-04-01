import MetalKit

class MetalImageView: MTKView {
    var inputHandler: InputHandler!

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)

        isPaused = true
        enableSetNeedsDisplay = true
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)
        layer?.isOpaque = true
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)

        setupGestureRecognizers()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("not implemented")
    }

    private func setupGestureRecognizers() {
        let magnification = NSMagnificationGestureRecognizer(
            target: self, action: #selector(handleMagnification(_:))
        )
        magnification.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(magnification)

        let pan = NSPanGestureRecognizer(
            target: self, action: #selector(handlePan(_:))
        )
        pan.numberOfTouchesRequired = 2
        pan.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(pan)
    }

    // MARK: - Key Events

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        inputHandler?.handleKeyDown(event: event, view: self)
    }

    // MARK: - Mouse Events

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        inputHandler?.handleMouseDown(event: event, view: self)
    }

    override func mouseDragged(with event: NSEvent) {
        inputHandler?.handleMouseDragged(event: event, view: self)
    }

    override func mouseUp(with event: NSEvent) {
        inputHandler?.handleMouseUp(event: event, view: self)
    }

    override func mouseMoved(with event: NSEvent) {
        inputHandler?.handleMouseMoved(event: event, view: self)
    }

    override func mouseExited(with event: NSEvent) {
        inputHandler?.handleMouseExited(view: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        inputHandler?.handleRightMouseDown(event: event, view: self)
    }

    override func otherMouseDown(with event: NSEvent) {
        inputHandler?.handleOtherMouseDown(event: event, view: self)
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let renderer = inputHandler?.renderer else { return }
        if renderer.mode == .image && renderer.scale > 1.0 {
            let edgeFrac: CGFloat = 0.15
            let leftEdge = CGRect(x: bounds.minX, y: bounds.minY,
                                  width: bounds.width * edgeFrac, height: bounds.height)
            let rightEdge = CGRect(x: bounds.maxX - bounds.width * edgeFrac, y: bounds.minY,
                                   width: bounds.width * edgeFrac, height: bounds.height)
            let center = CGRect(x: bounds.width * edgeFrac, y: bounds.minY,
                                width: bounds.width * (1.0 - 2.0 * edgeFrac), height: bounds.height)
            addCursorRect(center, cursor: .openHand)
            if renderer.hasMultipleImages {
                addCursorRect(leftEdge, cursor: .arrow)
                addCursorRect(rightEdge, cursor: .arrow)
            }
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
