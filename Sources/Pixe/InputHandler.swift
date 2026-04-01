import AppKit
import MetalKit

class InputHandler: NSObject {
    weak var renderer: Renderer?
    private var magnificationAnchor: Float = 1.0
    private var filenameSearchBuffer = ""
    private var filenameSearchActive = false
    private var filenameSearchStartIndex: Int?

    /// Currently hovered thumbnail index (nil when cursor is not over any item).
    var hoveredIndex: Int?
    /// Whether the mouse cursor is in the left edge zone (image mode nav).
    var mouseInLeftEdge = false
    /// Whether the mouse cursor is in the right edge zone (image mode nav).
    var mouseInRightEdge = false
    /// Whether a mouse drag occurred since the last mouseDown.
    private var didDragSinceMouseDown = false

    init(renderer: Renderer) {
        self.renderer = renderer
        super.init()
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

        if handleFilenameSearchControl(event: event, view: view) {
            return
        }
        if handleFilenameSearchCharacter(event: event, view: view) {
            return
        }
        if filenameSearchActive {
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

        case "s":
            renderer.toggleShuffle()

        case "m":
            renderer.generateMemoryReport()

        case "b":
            renderer.cycleSelectionEffect()
            view.needsDisplay = true

        case "v":
            renderer.cycleMorphEffect()
            view.needsDisplay = true

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

        case "y":
            renderer.copyCurrentImage()

        default:
            if event.characters == "G" {
                renderer.gridLayout.goToLast()
                renderer.updateInfoBar()
                view.needsDisplay = true
            } else if event.characters == "Y" {
                renderer.copyCurrentImagePath()
            } else if event.characters == "I" {
                renderer.ignoreCurrentFolder()
            } else {
                handleThumbnailArrowKeys(keyCode: event.keyCode, view: view)
            }
        }
    }

    private func handleFilenameSearchControl(event: NSEvent, view: MTKView) -> Bool {
        guard let renderer = renderer else { return false }

        switch event.keyCode {
        case 53:  // Escape
            if filenameSearchActive {
                cancelFilenameSearch(renderer: renderer, view: view)
                return true
            }
            return false

        case 51, 117:  // Backspace / Forward delete
            guard filenameSearchActive else { return false }
            guard !filenameSearchBuffer.isEmpty else { return true }
            filenameSearchBuffer.removeLast()
            if filenameSearchBuffer.isEmpty,
               let start = filenameSearchStartIndex,
               start < renderer.imageList.count
            {
                renderer.gridLayout.selectedIndex = start
                renderer.gridLayout.scrollToSelection()
            } else {
                jumpToFilenameMatch(prefix: filenameSearchBuffer, renderer: renderer, view: view)
            }
            renderer.setThumbnailSearchQuery(filenameSearchBuffer)
            view.needsDisplay = true
            return true

        case 36, 76:  // Return / Enter
            guard filenameSearchActive else { return false }
            commitFilenameSearch(renderer: renderer, view: view)
            return true

        default:
            break
        }

        if event.charactersIgnoringModifiers == "/" {
            filenameSearchActive = true
            filenameSearchBuffer = ""
            filenameSearchStartIndex = renderer.gridLayout.selectedIndex
            renderer.setThumbnailSearchQuery("")
            view.needsDisplay = true
            return true
        }

        return false
    }

    private func handleFilenameSearchCharacter(event: NSEvent, view: MTKView) -> Bool {
        guard let renderer = renderer else { return false }
        guard filenameSearchActive else { return false }
        guard isSearchEvent(event) else { return false }
        guard let chars = event.charactersIgnoringModifiers, chars.count == 1, let c = chars.first else {
            return false
        }
        guard isSearchCharacter(c) else { return false }

        let normalized = String(c).lowercased()
        filenameSearchBuffer += normalized
        jumpToFilenameMatch(prefix: filenameSearchBuffer, renderer: renderer, view: view)
        renderer.setThumbnailSearchQuery(filenameSearchBuffer)
        return true
    }

    private func jumpToFilenameMatch(prefix: String, renderer: Renderer, view: MTKView) {
        guard !prefix.isEmpty else { return }
        let paths = renderer.imageList.allPaths
        guard !paths.isEmpty else { return }

        let anchor = filenameSearchStartIndex ?? renderer.gridLayout.selectedIndex
        let start = (anchor + 1) % paths.count
        for offset in 0 ..< paths.count {
            let idx = (start + offset) % paths.count
            let name = (paths[idx] as NSString).lastPathComponent.lowercased()
            if name.hasPrefix(prefix) {
                renderer.gridLayout.selectedIndex = idx
                renderer.gridLayout.scrollToSelection()
                view.needsDisplay = true
                return
            }
        }
    }

    private func isSearchEvent(_ event: NSEvent) -> Bool {
        let blocked: NSEvent.ModifierFlags = [.command, .control, .option, .function]
        return event.modifierFlags.isDisjoint(with: blocked)
    }

    private func isSearchCharacter(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && scalar.value >= 32 && scalar.value <= 126
        }
    }

    private func cancelFilenameSearch(renderer: Renderer, view: MTKView) {
        if let index = filenameSearchStartIndex, index < renderer.imageList.count {
            renderer.gridLayout.selectedIndex = index
            renderer.gridLayout.scrollToSelection()
        }
        clearFilenameSearch(renderer: renderer)
        view.needsDisplay = true
    }

    private func commitFilenameSearch(renderer: Renderer, view: MTKView) {
        clearFilenameSearch(renderer: renderer)
        view.needsDisplay = true
    }

    private func clearFilenameSearch(renderer: Renderer) {
        filenameSearchBuffer = ""
        filenameSearchActive = false
        filenameSearchStartIndex = nil
        renderer.setThumbnailSearchQuery(nil)
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

        let panStep: Float = 0.1

        switch chars {
        case "q":
            if renderer.hasMultipleImages {
                renderer.enterThumbnailMode()
            } else {
                NSApp.terminate(nil)
            }

        case "f":
            view.window?.toggleFullScreen(nil)

        case "h":
            if renderer.scale > 1.0 {
                renderer.panBy(dx: panStep, dy: 0)
                view.needsDisplay = true
            } else {
                navigate(direction: -1, view: view)
            }

        case "l":
            if renderer.scale > 1.0 {
                renderer.panBy(dx: -panStep, dy: 0)
                view.needsDisplay = true
            } else {
                navigate(direction: 1, view: view)
            }

        case "j":
            if renderer.scale > 1.0 {
                renderer.panBy(dx: 0, dy: panStep)
                view.needsDisplay = true
            }

        case "k":
            if renderer.scale > 1.0 {
                renderer.panBy(dx: 0, dy: -panStep)
                view.needsDisplay = true
            }

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
            navigate(direction: 1, view: view)

        case "p":
            navigate(direction: -1, view: view)

        case "d":
            renderer.deleteImage(at: renderer.imageList.currentIndex)

        case "o":
            renderer.revealInFinder()

        case "i":
            renderer.toggleImageInfo()

        case "m":
            renderer.generateMemoryReport()

        case "g":
            renderer.stopAutoplay()
            renderer.imageList.goFirst()
            renderer.loadCurrentImage()

        case "r":
            renderer.rotateCW()
            view.needsDisplay = true

        case "s":
            renderer.toggleShuffle()

        case "a":
            renderer.toggleAutoplay()

        case "y":
            renderer.copyCurrentImage()

        default:
            if event.characters == "G" {
                renderer.stopAutoplay()
                renderer.imageList.goLast()
                renderer.loadCurrentImage()
            } else if event.characters == "Y" {
                renderer.copyCurrentImagePath()
            } else if event.characters == "I" {
                renderer.ignoreCurrentFolder()
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
            navigate(direction: -1, view: view)
        case 124:  // Right arrow
            navigate(direction: 1, view: view)
        default:
            break
        }
    }

    private func navigate(direction: Int, view: MTKView) {
        guard let renderer = renderer else { return }
        renderer.stopAutoplay()
        if renderer.config.strip && renderer.scale <= 1.0 && renderer.rotationSteps == 0 {
            renderer.navigateWithStripAnimation(direction: direction)
        } else {
            if direction > 0 { renderer.imageList.goNext() } else { renderer.imageList.goPrevious() }
            renderer.loadCurrentImage()
        }
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
        let vpH = renderer.gridLayout.viewportHeight

        if event.phase != [] || event.momentumPhase != [] {
            // Trackpad: already has momentum, apply directly
            let delta = Float(-event.scrollingDeltaY) * 3.0
            renderer.gridLayout.scrollBy(delta: delta)
            view.needsDisplay = true
        } else {
            // Discrete mouse wheel: scroll ~20% of viewport per notch, animated
            let delta = Float(-event.scrollingDeltaY) * vpH * 0.2
            renderer.smoothScrollBy(delta: delta)
        }
        renderer.showScrollbar()
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

    // MARK: - Mouse Click Handling

    /// Convert a window event location to GridLayout point-space (origin top-left).
    private func gridPoint(event: NSEvent, view: MTKView) -> (x: Float, y: Float) {
        let local = view.convert(event.locationInWindow, from: nil)
        return (Float(local.x), Float(view.bounds.height - local.y))
    }

    func handleMouseDown(event: NSEvent, view: MTKView) {
        guard let renderer = renderer else { return }
        didDragSinceMouseDown = false

        switch renderer.mode {
        case .thumbnail:
            handleThumbnailMouseDown(event: event, view: view)
        case .image:
            // When zoomed, set drag cursor; otherwise defer action to mouseUp
            if renderer.scale > 1.0 {
                NSCursor.closedHand.set()
            }
        }
    }

    func handleMouseDragged(event: NSEvent, view: MTKView) {
        guard let renderer = renderer, renderer.mode == .image else { return }
        didDragSinceMouseDown = true

        if renderer.scale > 1.0 {
            let dx = Float(event.deltaX) / Float(view.bounds.width) * 2.0
            let dy = Float(-event.deltaY) / Float(view.bounds.height) * 2.0
            renderer.panBy(dx: dx, dy: dy)
            view.needsDisplay = true
        }
    }

    func handleMouseUp(event: NSEvent, view: MTKView) {
        guard let renderer = renderer else { return }

        switch renderer.mode {
        case .thumbnail:
            break
        case .image:
            if renderer.scale > 1.0 {
                NSCursor.openHand.set()
            }
            // Only trigger click actions if user didn't drag
            if !didDragSinceMouseDown {
                handleImageMouseClick(event: event, view: view)
            }
        }
        didDragSinceMouseDown = false
    }

    private func handleThumbnailMouseDown(event: NSEvent, view: MTKView) {
        guard let renderer = renderer else { return }
        let pt = gridPoint(event: event, view: view)

        guard let hitIndex = renderer.gridLayout.itemIndex(at: pt) else { return }

        renderer.enterImageMode(at: hitIndex)
    }

    private func handleImageMouseClick(event: NSEvent, view: MTKView) {
        guard let renderer = renderer else { return }
        let local = view.convert(event.locationInWindow, from: nil)
        let xFrac = local.x / view.bounds.width
        let edgeZone: CGFloat = 0.15

        // Edge zones: always navigate (any click count)
        if xFrac < edgeZone && renderer.hasMultipleImages {
            navigate(direction: -1, view: view)
            return
        }
        if xFrac > (1.0 - edgeZone) && renderer.hasMultipleImages {
            navigate(direction: 1, view: view)
            return
        }

        // Center zone: click returns to grid
        if renderer.hasMultipleImages {
            renderer.enterThumbnailMode()
        }
    }

    // MARK: - Mouse Move / Hover

    func handleMouseMoved(event: NSEvent, view: MTKView) {
        guard let renderer = renderer else { return }

        switch renderer.mode {
        case .thumbnail:
            handleThumbnailMouseMoved(event: event, view: view)
        case .image:
            handleImageMouseMoved(event: event, view: view)
        }
    }

    private func handleThumbnailMouseMoved(event: NSEvent, view: MTKView) {
        guard let renderer = renderer else { return }
        guard renderer.config.chrome else { return }

        let pt = gridPoint(event: event, view: view)
        let newHover = renderer.gridLayout.itemIndex(at: pt)

        if newHover != hoveredIndex {
            hoveredIndex = newHover
            view.needsDisplay = true
        }

        renderer.showScrollbar()
    }

    private func handleImageMouseMoved(event: NSEvent, view: MTKView) {
        guard let renderer = renderer else { return }
        guard renderer.config.chrome else { return }

        let local = view.convert(event.locationInWindow, from: nil)
        let xFrac = Float(local.x / view.bounds.width)

        let edgeZone: Float = 0.15
        let wasLeft = mouseInLeftEdge
        let wasRight = mouseInRightEdge
        mouseInLeftEdge = xFrac < edgeZone && renderer.hasMultipleImages
        mouseInRightEdge = xFrac > (1.0 - edgeZone) && renderer.hasMultipleImages

        if mouseInLeftEdge || mouseInRightEdge {
            renderer.showNavButtons()
        } else if wasLeft || wasRight {
            renderer.scheduleHideNavButtons()
        }

        if mouseInLeftEdge != wasLeft || mouseInRightEdge != wasRight {
            view.needsDisplay = true
        }
    }

    func handleMouseExited(view: MTKView) {
        guard let renderer = renderer else { return }

        if hoveredIndex != nil {
            hoveredIndex = nil
            view.needsDisplay = true
        }
        mouseInLeftEdge = false
        mouseInRightEdge = false
        if renderer.config.chrome {
            renderer.scheduleHideNavButtons()
        }
    }

    // MARK: - Context Menu

    func handleRightMouseDown(event: NSEvent, view: MTKView) {
        guard let renderer = renderer else { return }
        let menu = buildContextMenu(renderer: renderer)
        menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
    }

    func handleOtherMouseDown(event: NSEvent, view: MTKView) {
        guard let renderer = renderer else { return }
        // Mouse button 3 = back, button 4 = forward
        switch event.buttonNumber {
        case 3:
            switch renderer.mode {
            case .thumbnail:
                renderer.gridLayout.moveLeft()
                renderer.updateInfoBar()
                view.needsDisplay = true
            case .image:
                navigate(direction: -1, view: view)
            }
        case 4:
            switch renderer.mode {
            case .thumbnail:
                renderer.gridLayout.moveRight()
                renderer.updateInfoBar()
                view.needsDisplay = true
            case .image:
                navigate(direction: 1, view: view)
            }
        default:
            break
        }
    }

    private func buildContextMenu(renderer: Renderer) -> NSMenu {
        let menu = NSMenu()

        switch renderer.mode {
        case .thumbnail:
            buildThumbnailContextMenu(menu: menu, renderer: renderer)
        case .image:
            buildImageContextMenu(menu: menu, renderer: renderer)
        }

        return menu
    }

    private func buildThumbnailContextMenu(menu: NSMenu, renderer: Renderer) {
        menu.addItem(menuItem("Open", action: #selector(contextOpen), key: "↩"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Reveal in Finder", action: #selector(contextRevealInFinder), key: "o"))
        menu.addItem(menuItem("Copy Image", action: #selector(contextCopyImage), key: "y"))
        menu.addItem(menuItem("Copy Path", action: #selector(contextCopyPath), key: "Y"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Image Info", action: #selector(contextToggleImageInfo), key: "i"))
        menu.addItem(menuItem("Ignore Folder", action: #selector(contextIgnoreFolder), key: "I"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Zoom In", action: #selector(contextZoomIn), key: "+"))
        menu.addItem(menuItem("Zoom Out", action: #selector(contextZoomOut), key: "-"))
        menu.addItem(menuItem("Reset Zoom", action: #selector(contextResetZoom), key: "0"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Shuffle", action: #selector(contextShuffle), key: "s"))
        menu.addItem(menuItem("Selection Effect", action: #selector(contextCycleSelectionEffect), key: "b"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Move to Trash", action: #selector(contextDelete), key: "d"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Fullscreen", action: #selector(contextFullscreen), key: "f"))
        menu.addItem(menuItem("Quit", action: #selector(contextQuit), key: "q"))
    }

    private func buildImageContextMenu(menu: NSMenu, renderer: Renderer) {
        if renderer.hasMultipleImages {
            menu.addItem(menuItem("Back to Grid", action: #selector(contextBackToGrid), key: "q"))
            menu.addItem(menuItem("Next Image", action: #selector(contextNextImage), key: "n"))
            menu.addItem(menuItem("Previous Image", action: #selector(contextPrevImage), key: "p"))
            menu.addItem(.separator())
        }
        menu.addItem(menuItem("Reveal in Finder", action: #selector(contextRevealInFinder), key: "o"))
        menu.addItem(menuItem("Copy Image", action: #selector(contextCopyImage), key: "y"))
        menu.addItem(menuItem("Copy Path", action: #selector(contextCopyPath), key: "Y"))
        menu.addItem(menuItem("Image Info", action: #selector(contextToggleImageInfo), key: "i"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Rotate CW", action: #selector(contextRotate), key: "r"))
        menu.addItem(menuItem("Reset View", action: #selector(contextResetView), key: "0"))
        menu.addItem(.separator())
        if renderer.hasMultipleImages {
            let autoplayItem = menuItem("Autoplay", action: #selector(contextToggleAutoplay), key: "a")
            if renderer.isAutoplayActive {
                autoplayItem.state = .on
            }
            menu.addItem(autoplayItem)
            menu.addItem(menuItem("Shuffle", action: #selector(contextShuffle), key: "s"))
            menu.addItem(.separator())
        }
        menu.addItem(menuItem("Move to Trash", action: #selector(contextDelete), key: "d"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Fullscreen", action: #selector(contextFullscreen), key: "f"))
        menu.addItem(menuItem("Quit", action: #selector(contextQuit), key: "q"))
    }

    private func menuItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        // Show key hint in the menu item (non-functional, just informational)
        let attrTitle = NSMutableAttributedString(string: title)
        let keyHint = NSAttributedString(
            string: "  \(key)",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor]
        )
        attrTitle.append(keyHint)
        item.attributedTitle = attrTitle
        return item
    }

    // MARK: - Context Menu Actions

    @objc private func contextOpen() {
        guard let renderer = renderer else { return }
        renderer.enterImageMode(at: renderer.gridLayout.selectedIndex)
    }

    @objc private func contextBackToGrid() {
        renderer?.enterThumbnailMode()
    }

    @objc private func contextNextImage() {
        guard let view = renderer?.window?.contentView as? MTKView else { return }
        navigate(direction: 1, view: view)
    }

    @objc private func contextPrevImage() {
        guard let view = renderer?.window?.contentView as? MTKView else { return }
        navigate(direction: -1, view: view)
    }

    @objc private func contextRevealInFinder() {
        renderer?.revealInFinder()
    }

    @objc private func contextCopyImage() {
        renderer?.copyCurrentImage()
    }

    @objc private func contextCopyPath() {
        renderer?.copyCurrentImagePath()
    }

    @objc private func contextToggleImageInfo() {
        renderer?.toggleImageInfo()
    }

    @objc private func contextIgnoreFolder() {
        renderer?.ignoreCurrentFolder()
    }

    @objc private func contextZoomIn() {
        guard let renderer = renderer, let view = renderer.window?.contentView as? MTKView else { return }
        renderer.gridLayout.zoomBy(factor: 1.15)
        renderer.updateInfoBar()
        view.needsDisplay = true
    }

    @objc private func contextZoomOut() {
        guard let renderer = renderer, let view = renderer.window?.contentView as? MTKView else { return }
        renderer.gridLayout.zoomBy(factor: 0.87)
        renderer.updateInfoBar()
        view.needsDisplay = true
    }

    @objc private func contextResetZoom() {
        guard let renderer = renderer, let view = renderer.window?.contentView as? MTKView else { return }
        renderer.gridLayout.resetZoom()
        renderer.updateInfoBar()
        view.needsDisplay = true
    }

    @objc private func contextShuffle() {
        renderer?.toggleShuffle()
    }

    @objc private func contextCycleSelectionEffect() {
        guard let view = renderer?.window?.contentView as? MTKView else { return }
        renderer?.cycleSelectionEffect()
        view.needsDisplay = true
    }

    @objc private func contextDelete() {
        guard let renderer = renderer else { return }
        let index = renderer.mode == .thumbnail
            ? renderer.gridLayout.selectedIndex
            : renderer.imageList.currentIndex
        renderer.deleteImage(at: index)
    }

    @objc private func contextFullscreen() {
        renderer?.window?.toggleFullScreen(nil)
    }

    @objc private func contextQuit() {
        NSApp.terminate(nil)
    }

    @objc private func contextRotate() {
        guard let view = renderer?.window?.contentView as? MTKView else { return }
        renderer?.rotateCW()
        view.needsDisplay = true
    }

    @objc private func contextResetView() {
        guard let renderer = renderer, let view = renderer.window?.contentView as? MTKView else { return }
        renderer.resetView()
        view.window?.invalidateCursorRects(for: view)
        view.needsDisplay = true
    }

    @objc private func contextToggleAutoplay() {
        renderer?.toggleAutoplay()
    }
}
