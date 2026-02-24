import AppKit
import MetalKit

class InputHandler {
    weak var renderer: Renderer?
    private var magnificationAnchor: Float = 1.0
    private var filenameSearchBuffer = ""
    private var filenameSearchForced = false
    private var filenameSearchLastInputNs: UInt64 = 0
    private let filenameSearchTimeoutNs: UInt64 = 1_200_000_000

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

        expireFilenameSearchIfNeeded()

        if handleFilenameSearchControl(event: event, view: view) {
            return
        }
        if handleFilenameSearchCharacter(event: event, view: view) {
            return
        }

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

        case "o":
            renderer.revealInFinder()

        case "i":
            renderer.toggleImageInfo()

        case "d":
            renderer.deleteImage(at: renderer.gridLayout.selectedIndex)

        case "n":
            renderer.gridLayout.pageDown()
            renderer.updateInfoBar()
            view.needsDisplay = true

        case "p":
            renderer.gridLayout.pageUp()
            renderer.updateInfoBar()
            view.needsDisplay = true

        case "m":
            renderer.generateMemoryReport()

        case "+", "=":
            renderer.gridLayout.zoomBy(factor: 1.15)
            renderer.updateInfoBar()
            view.needsDisplay = true

        case "-":
            renderer.gridLayout.zoomBy(factor: 0.87)
            renderer.updateInfoBar()
            view.needsDisplay = true

        case "0":
            renderer.gridLayout.resetZoom()
            renderer.updateInfoBar()
            view.needsDisplay = true

        case "g":
            renderer.gridLayout.goToFirst()
            renderer.updateInfoBar()
            view.needsDisplay = true

        default:
            if event.characters == "G" {
                renderer.gridLayout.goToLast()
                renderer.updateInfoBar()
                view.needsDisplay = true
            } else {
                handleThumbnailArrowKeys(keyCode: event.keyCode, view: view)
            }
        }
    }

    private func handleFilenameSearchControl(event: NSEvent, view: MTKView) -> Bool {
        guard let renderer = renderer else { return false }

        switch event.keyCode {
        case 53:  // Escape
            if filenameSearchForced || !filenameSearchBuffer.isEmpty {
                clearFilenameSearch()
                return true
            }
            return false

        case 51, 117:  // Backspace / Forward delete
            guard !filenameSearchBuffer.isEmpty else { return false }
            filenameSearchBuffer.removeLast()
            filenameSearchLastInputNs = DispatchTime.now().uptimeNanoseconds
            if filenameSearchBuffer.isEmpty {
                filenameSearchForced = false
            } else {
                jumpToFilenameMatch(prefix: filenameSearchBuffer, renderer: renderer, view: view)
            }
            return true

        default:
            break
        }

        if event.charactersIgnoringModifiers == "/" {
            filenameSearchForced = true
            filenameSearchBuffer = ""
            filenameSearchLastInputNs = DispatchTime.now().uptimeNanoseconds
            return true
        }

        return false
    }

    private func handleFilenameSearchCharacter(event: NSEvent, view: MTKView) -> Bool {
        guard let renderer = renderer else { return false }
        guard isSearchEvent(event) else { return false }
        guard let chars = event.charactersIgnoringModifiers, chars.count == 1, let c = chars.first else {
            return false
        }
        guard isSearchCharacter(c) else { return false }

        let normalized = String(c).lowercased()
        if !filenameSearchForced && isReservedThumbnailKey(normalized) {
            return false
        }

        if !filenameSearchForced && isSearchExpired() {
            filenameSearchBuffer = ""
        }
        filenameSearchBuffer += normalized
        filenameSearchLastInputNs = DispatchTime.now().uptimeNanoseconds
        jumpToFilenameMatch(prefix: filenameSearchBuffer, renderer: renderer, view: view)
        return true
    }

    private func jumpToFilenameMatch(prefix: String, renderer: Renderer, view: MTKView) {
        guard !prefix.isEmpty else { return }
        let paths = renderer.imageList.allPaths
        guard !paths.isEmpty else { return }

        let start = (renderer.gridLayout.selectedIndex + 1) % paths.count
        for offset in 0..<paths.count {
            let idx = (start + offset) % paths.count
            let name = (paths[idx] as NSString).lastPathComponent.lowercased()
            if name.hasPrefix(prefix) {
                renderer.gridLayout.selectedIndex = idx
                renderer.gridLayout.scrollToSelection()
                renderer.updateInfoBar()
                view.needsDisplay = true
                return
            }
        }
    }

    private func isSearchEvent(_ event: NSEvent) -> Bool {
        let blocked: NSEvent.ModifierFlags = [.command, .control, .option, .function]
        return event.modifierFlags.intersection(blocked).isEmpty
    }

    private func isSearchCharacter(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && scalar.value >= 33 && scalar.value <= 126
        }
    }

    private func isReservedThumbnailKey(_ normalized: String) -> Bool {
        let reserved: Set<String> = [
            "q", "f", "h", "j", "k", "l", "o", "i", "d", "n", "p", "m", "g", " ", "+", "=", "-", "0"
        ]
        return reserved.contains(normalized)
    }

    private func isSearchExpired() -> Bool {
        guard filenameSearchLastInputNs != 0 else { return true }
        let now = DispatchTime.now().uptimeNanoseconds
        return now - filenameSearchLastInputNs > filenameSearchTimeoutNs
    }

    private func expireFilenameSearchIfNeeded() {
        guard (filenameSearchForced || !filenameSearchBuffer.isEmpty), isSearchExpired() else { return }
        clearFilenameSearch()
    }

    private func clearFilenameSearch() {
        filenameSearchBuffer = ""
        filenameSearchForced = false
        filenameSearchLastInputNs = 0
    }

    private func handleThumbnailArrowKeys(keyCode: UInt16, view: MTKView) {
        guard let renderer = renderer else { return }

        switch keyCode {
        case 123:  // Left
            renderer.gridLayout.moveLeft()
            renderer.updateInfoBar()
            view.needsDisplay = true
        case 124:  // Right
            renderer.gridLayout.moveRight()
            renderer.updateInfoBar()
            view.needsDisplay = true
        case 125:  // Down
            renderer.gridLayout.moveDown()
            renderer.updateInfoBar()
            view.needsDisplay = true
        case 126:  // Up
            renderer.gridLayout.moveUp()
            renderer.updateInfoBar()
            view.needsDisplay = true
        case 36:  // Enter/Return
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

        case "d":
            renderer.deleteImage(at: renderer.imageList.currentIndex)

        case "o":
            renderer.revealInFinder()

        case "i":
            renderer.toggleImageInfo()

        case "m":
            renderer.generateMemoryReport()

        case "g":
            renderer.imageList.goFirst()
            renderer.loadCurrentImage()

        default:
            if event.characters == "G" {
                renderer.imageList.goLast()
                renderer.loadCurrentImage()
            } else {
                handleImageArrowKeys(keyCode: event.keyCode, view: view)
            }
        }
    }

    private func handleImageArrowKeys(keyCode: UInt16, view: MTKView) {
        switch keyCode {
        case 53:  // Escape
            if renderer?.hasMultipleImages == true {
                renderer?.enterThumbnailMode()
            }
        case 36:  // Enter/Return
            if renderer?.hasMultipleImages == true {
                renderer?.enterThumbnailMode()
            }
        case 123:  // Left arrow
            navigatePrevious(view: view)
        case 124:  // Right arrow
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

    // MARK: - Trackpad Gestures

    func handleMagnification(gesture: NSMagnificationGestureRecognizer, view: MTKView) {
        guard let renderer = renderer else { return }

        switch renderer.mode {
        case .image:
            switch gesture.state {
            case .began:
                magnificationAnchor = renderer.scale
            case .changed:
                let newScale = magnificationAnchor * (1.0 + Float(gesture.magnification))
                renderer.setScale(newScale)
                view.needsDisplay = true
            default:
                break
            }

        case .thumbnail:
            switch gesture.state {
            case .changed:
                let factor = max(0.7, min(1.3, 1.0 + Float(gesture.magnification)))
                renderer.gridLayout.zoomBy(factor: factor)
                renderer.updateInfoBar()
                view.needsDisplay = true
            default:
                break
            }
        }
    }

    func handlePan(gesture: NSPanGestureRecognizer, view: MTKView) {
        guard renderer?.mode == .image else { return }

        switch gesture.state {
        case .began:
            NSCursor.closedHand.set()
        case .changed:
            let t = gesture.translation(in: view)
            let dx = Float(t.x) / Float(view.bounds.width) * 2.0
            let dy = Float(t.y) / Float(view.bounds.height) * 2.0
            renderer?.panBy(dx: dx, dy: dy)
            gesture.setTranslation(.zero, in: view)
            view.needsDisplay = true
        case .ended, .cancelled:
            if renderer?.scale ?? 1.0 > 1.0 {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        default:
            break
        }
    }
}
