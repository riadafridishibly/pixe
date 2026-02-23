import AppKit
import MetalKit

class InputHandler {
    weak var renderer: Renderer?
    private var magnificationAnchor: Float = 1.0

    init(renderer: Renderer) {
        self.renderer = renderer
    }

    func handleKeyDown(event: NSEvent, view: MTKView) {
        guard let renderer = renderer else { return }

        switch renderer.mode {
        case .thumbnail:
            handleThumbnailKeyDown(event: event, view: view)
        case .image:
            handleImageKeyDown(event: event, view: view)
        }
    }

    // MARK: - Thumbnail Mode Keys

    private func handleThumbnailKeyDown(event: NSEvent, view: MTKView) {
        guard let renderer = renderer else { return }
        guard let chars = event.charactersIgnoringModifiers else { return }

        switch chars {
        case "q":
            NSApp.terminate(nil)

        case "f":
            view.window?.toggleFullScreen(nil)

        case "h":
            renderer.gridLayout.moveLeft()
            renderer.updateInfoBar()
            view.needsDisplay = true

        case "j":
            renderer.gridLayout.moveDown()
            renderer.updateInfoBar()
            view.needsDisplay = true

        case "k":
            renderer.gridLayout.moveUp()
            renderer.updateInfoBar()
            view.needsDisplay = true

        case "l":
            renderer.gridLayout.moveRight()
            renderer.updateInfoBar()
            view.needsDisplay = true

        case "g":
            if event.modifierFlags.contains(.shift) {
                renderer.gridLayout.goToLast()
            } else {
                renderer.gridLayout.goToFirst()
            }
            renderer.updateInfoBar()
            view.needsDisplay = true

        default:
            handleThumbnailArrowKeys(keyCode: event.keyCode, view: view)
        }
    }

    private func handleThumbnailArrowKeys(keyCode: UInt16, view: MTKView) {
        guard let renderer = renderer else { return }

        switch keyCode {
        case 123: // Left
            renderer.gridLayout.moveLeft()
            renderer.updateInfoBar()
            view.needsDisplay = true
        case 124: // Right
            renderer.gridLayout.moveRight()
            renderer.updateInfoBar()
            view.needsDisplay = true
        case 125: // Down
            renderer.gridLayout.moveDown()
            renderer.updateInfoBar()
            view.needsDisplay = true
        case 126: // Up
            renderer.gridLayout.moveUp()
            renderer.updateInfoBar()
            view.needsDisplay = true
        case 36: // Enter/Return
            renderer.enterImageMode(at: renderer.gridLayout.selectedIndex)
        default:
            break
        }
    }

    // MARK: - Image Mode Keys

    private func handleImageKeyDown(event: NSEvent, view: MTKView) {
        guard let renderer = renderer else { return }
        guard let chars = event.charactersIgnoringModifiers else { return }

        switch chars {
        case "q":
            if renderer.hasMultipleImages {
                renderer.enterThumbnailMode()
            } else {
                NSApp.terminate(nil)
            }

        case "f":
            view.window?.toggleFullScreen(nil)

        case "+", "=":
            renderer.zoomBy(factor: 1.25)
            view.window?.invalidateCursorRects(for: view)
            view.needsDisplay = true

        case "-":
            renderer.zoomBy(factor: 0.8)
            view.window?.invalidateCursorRects(for: view)
            view.needsDisplay = true

        case "0":
            renderer.resetView()
            view.window?.invalidateCursorRects(for: view)
            view.needsDisplay = true

        case "n", " ":
            navigateNext(view: view)

        case "p":
            navigatePrevious(view: view)

        case "g":
            if event.modifierFlags.contains(.shift) {
                renderer.imageList.goLast()
            } else {
                renderer.imageList.goFirst()
            }
            renderer.loadCurrentImage()

        default:
            handleImageArrowKeys(keyCode: event.keyCode, view: view)
        }
    }

    private func handleImageArrowKeys(keyCode: UInt16, view: MTKView) {
        switch keyCode {
        case 53: // Escape
            if renderer?.hasMultipleImages == true {
                renderer?.enterThumbnailMode()
            }
        case 36: // Enter/Return
            if renderer?.hasMultipleImages == true {
                renderer?.enterThumbnailMode()
            }
        case 123: // Left arrow
            navigatePrevious(view: view)
        case 124: // Right arrow
            navigateNext(view: view)
        default:
            break
        }
    }

    private func navigateNext(view: MTKView) {
        renderer?.imageList.goNext()
        renderer?.loadCurrentImage()
    }

    private func navigatePrevious(view: MTKView) {
        renderer?.imageList.goPrevious()
        renderer?.loadCurrentImage()
    }

    // MARK: - Scroll Wheel

    func handleScrollWheel(event: NSEvent, view: MTKView) {
        guard let renderer = renderer else { return }

        switch renderer.mode {
        case .thumbnail:
            handleThumbnailScroll(event: event, view: view)
        case .image:
            handleImageScroll(event: event, view: view)
        }
    }

    private func handleThumbnailScroll(event: NSEvent, view: MTKView) {
        guard let renderer = renderer else { return }
        let delta = Float(-event.scrollingDeltaY) * 2.0
        renderer.gridLayout.scrollBy(delta: delta)
        view.needsDisplay = true
    }

    private func handleImageScroll(event: NSEvent, view: MTKView) {
        if event.phase != [] || event.momentumPhase != [] {
            let dx = Float(event.scrollingDeltaX) / Float(view.bounds.width) * 2.0
            let dy = Float(-event.scrollingDeltaY) / Float(view.bounds.height) * 2.0
            renderer?.panBy(dx: dx, dy: dy)
            view.needsDisplay = true
        } else {
            let zoomFactor: Float = 1.0 + Float(event.scrollingDeltaY) * 0.05
            renderer?.zoomBy(factor: zoomFactor)
            view.needsDisplay = true
        }
    }

    // MARK: - Mouse Drag

    func handleMouseDown(event: NSEvent, view: MTKView) {
        guard renderer?.mode == .image else { return }
        NSCursor.closedHand.set()
    }

    func handleMouseDragged(event: NSEvent, view: MTKView) {
        guard renderer?.mode == .image else { return }
        let dx = Float(-event.deltaX) / Float(view.bounds.width) * 2.0
        let dy = Float(event.deltaY) / Float(view.bounds.height) * 2.0
        renderer?.panBy(dx: dx, dy: dy)
        view.needsDisplay = true
    }

    func handleMouseUp(event: NSEvent, view: MTKView) {
        guard renderer?.mode == .image else { return }
        if renderer?.scale ?? 1.0 > 1.0 {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Trackpad Gestures

    func handleMagnification(gesture: NSMagnificationGestureRecognizer, view: MTKView) {
        guard renderer?.mode == .image else { return }

        switch gesture.state {
        case .began:
            magnificationAnchor = renderer?.scale ?? 1.0
        case .changed:
            let newScale = magnificationAnchor * (1.0 + Float(gesture.magnification))
            renderer?.setScale(newScale)
            view.needsDisplay = true
        default:
            break
        }
    }

    func handlePan(gesture: NSPanGestureRecognizer, view: MTKView) {
        guard renderer?.mode == .image else { return }

        let t = gesture.translation(in: view)
        let dx = Float(t.x) / Float(view.bounds.width) * 2.0
        let dy = Float(-t.y) / Float(view.bounds.height) * 2.0

        renderer?.panBy(dx: dx, dy: dy)
        gesture.setTranslation(.zero, in: view)
        view.needsDisplay = true
    }
}
