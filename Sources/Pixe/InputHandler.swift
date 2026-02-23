import AppKit
import MetalKit

class InputHandler {
    weak var renderer: Renderer?
    private var magnificationAnchor: Float = 1.0

    init(renderer: Renderer) {
        self.renderer = renderer
    }

    func handleKeyDown(event: NSEvent, view: MTKView) {
        guard let chars = event.charactersIgnoringModifiers else { return }

        switch chars {
        case "q":
            NSApp.terminate(nil)

        case "f":
            view.window?.toggleFullScreen(nil)

        // Zoom
        case "+", "=":
            renderer?.zoomBy(factor: 1.25)
            view.needsDisplay = true

        case "-":
            renderer?.zoomBy(factor: 0.8)
            view.needsDisplay = true

        case "0":
            renderer?.resetView()
            view.needsDisplay = true

        // Navigation
        case "n", " ":
            navigateNext(view: view)

        case "p":
            navigatePrevious(view: view)

        case "g":
            if event.modifierFlags.contains(.shift) {
                renderer?.imageList.goLast()
            } else {
                renderer?.imageList.goFirst()
            }
            renderer?.loadCurrentImage()

        default:
            handleArrowKeys(keyCode: event.keyCode, view: view)
        }
    }

    private func handleArrowKeys(keyCode: UInt16, view: MTKView) {
        switch keyCode {
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
        if event.phase != [] || event.momentumPhase != [] {
            // Trackpad scroll — pan
            let dx = Float(event.scrollingDeltaX) / Float(view.bounds.width) * 2.0
            let dy = Float(-event.scrollingDeltaY) / Float(view.bounds.height) * 2.0
            renderer?.panBy(dx: dx, dy: dy)
            view.needsDisplay = true
        } else {
            // Mouse scroll wheel — zoom
            let zoomFactor: Float = 1.0 + Float(event.scrollingDeltaY) * 0.05
            renderer?.zoomBy(factor: zoomFactor)
            view.needsDisplay = true
        }
    }

    // MARK: - Trackpad Gestures

    func handleMagnification(gesture: NSMagnificationGestureRecognizer, view: MTKView) {
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
        let t = gesture.translation(in: view)
        let dx = Float(t.x) / Float(view.bounds.width) * 2.0
        let dy = Float(-t.y) / Float(view.bounds.height) * 2.0

        renderer?.panBy(dx: dx, dy: dy)
        gesture.setTranslation(.zero, in: view)
        view.needsDisplay = true
    }
}
