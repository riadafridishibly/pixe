import AppKit
import MetalKit

extension Renderer {
    // MARK: - Autoplay

    func enableStartupAutoplay() {
        startupAutoplayPending = true
        startPendingAutoplayIfPossible()
    }

    func toggleAutoplay() {
        if isAutoplayActive {
            stopAutoplay()
        } else {
            startAutoplay()
        }
        updateInfoBar()
    }

    func startAutoplay() {
        stopAutoplay()
        guard mode == .image else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        autoplayTimer = timer
        timer.schedule(deadline: .now() + autoplayInterval, repeating: autoplayInterval)
        timer.setEventHandler { [weak self] in
            self?.autoplayAdvance()
        }
        timer.resume()
    }

    func stopAutoplay() {
        guard autoplayTimer != nil else { return }
        autoplayTimer?.cancel()
        autoplayTimer = nil
        updateInfoBar()
    }

    func startSelectionAnimation() {
        guard selectionAnimationTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.mode == .thumbnail else { return }
            if let view = self.window?.contentView as? MTKView {
                view.needsDisplay = true
            }
        }
        timer.resume()
        selectionAnimationTimer = timer
    }

    func stopSelectionAnimation() {
        selectionAnimationTimer?.cancel()
        selectionAnimationTimer = nil
    }

    func cycleSelectionEffect() {
        selectionEffect = selectionEffect.next()
        updateInfoBar()
        if let view = window?.contentView as? MTKView {
            view.needsDisplay = true
        }
    }

    func cycleMorphEffect() {
        morphEffect = morphEffect.next()
        updateInfoBar()
        if let view = window?.contentView as? MTKView {
            view.needsDisplay = true
        }
    }

    private func autoplayAdvance() {
        guard mode == .image else {
            stopAutoplay()
            return
        }
        if config.strip {
            navigateWithStripAnimation(direction: 1)
        } else {
            imageList.goNext()
            loadCurrentImage()
        }
    }

    func startPendingAutoplayIfPossible() {
        guard startupAutoplayPending else { return }
        guard imageList.count > 0 else { return }
        if mode == .thumbnail {
            enterImageMode(at: imageList.currentIndex)
        } else if mode == .image, currentTexture == nil {
            loadCurrentImage()
        }
        startAutoplay()
        if isAutoplayActive {
            startupAutoplayPending = false
        }
    }

    // MARK: - Smooth Scroll

    func smoothScrollBy(delta: Float) {
        let baseOffset = scrollAnimationTimer == nil ? gridLayout.scrollOffset : scrollTarget
        scrollTarget = baseOffset + delta
        // Clamp target to valid range
        let maxScroll = max(0, gridLayout.totalHeight - gridLayout.viewportHeight)
        scrollTarget = max(0, min(scrollTarget, maxScroll))
        startScrollAnimation()
    }

    func cancelThumbnailSmoothScroll() {
        stopScrollAnimation()
    }

    private func startScrollAnimation() {
        guard scrollAnimationTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        timer.setEventHandler { [weak self] in
            self?.updateScrollAnimation()
        }
        timer.resume()
        scrollAnimationTimer = timer
    }

    private func updateScrollAnimation() {
        let current = gridLayout.scrollOffset
        let diff = scrollTarget - current

        if abs(diff) < 0.5 {
            gridLayout.scrollOffset = scrollTarget
            gridLayout.clampScroll()
            scrollAnimationTimer?.cancel()
            scrollAnimationTimer = nil
        } else {
            gridLayout.scrollOffset += diff * 0.22
            gridLayout.clampScroll()
        }

        if let view = window?.contentView as? MTKView {
            view.needsDisplay = true
        }
    }

    func stopScrollAnimation() {
        scrollAnimationTimer?.cancel()
        scrollAnimationTimer = nil
        scrollTarget = gridLayout.scrollOffset
    }

    // MARK: - Chrome Auto-Hide

    func showScrollbar() {
        guard config.chrome else { return }
        chromeScrollbarTarget = 0.6
        startChromeAnimation()
        // Reset hide timer
        scrollbarHideTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.5)
        timer.setEventHandler { [weak self] in
            self?.chromeScrollbarTarget = 0.0
            self?.startChromeAnimation()
        }
        timer.resume()
        scrollbarHideTimer = timer
    }

    func showNavButtons() {
        guard config.chrome else { return }
        chromeNavButtonTarget = 0.7
        startChromeAnimation()
        navButtonHideTimer?.cancel()
        navButtonHideTimer = nil
    }

    func scheduleHideNavButtons() {
        guard config.chrome else { return }
        navButtonHideTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0)
        timer.setEventHandler { [weak self] in
            self?.chromeNavButtonTarget = 0.0
            self?.startChromeAnimation()
        }
        timer.resume()
        navButtonHideTimer = timer
    }

    private func startChromeAnimation() {
        guard chromeAnimationTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self] in
            self?.updateChromeAnimation()
        }
        timer.resume()
        chromeAnimationTimer = timer
    }

    private func updateChromeAnimation() {
        let speed: Float = 0.15
        chromeScrollbarAlpha += (chromeScrollbarTarget - chromeScrollbarAlpha) * speed
        chromeNavButtonAlpha += (chromeNavButtonTarget - chromeNavButtonAlpha) * speed

        // Snap to target when close enough
        if abs(chromeScrollbarAlpha - chromeScrollbarTarget) < 0.01 {
            chromeScrollbarAlpha = chromeScrollbarTarget
        }
        if abs(chromeNavButtonAlpha - chromeNavButtonTarget) < 0.01 {
            chromeNavButtonAlpha = chromeNavButtonTarget
        }

        // Stop timer when all animations are settled
        if chromeScrollbarAlpha == chromeScrollbarTarget && chromeNavButtonAlpha == chromeNavButtonTarget {
            chromeAnimationTimer?.cancel()
            chromeAnimationTimer = nil
        }

        if let view = window?.contentView as? MTKView {
            view.needsDisplay = true
        }
    }

    func resetChrome() {
        chromeScrollbarAlpha = 0
        chromeScrollbarTarget = 0
        chromeNavButtonAlpha = 0
        chromeNavButtonTarget = 0
        scrollbarHideTimer?.cancel()
        scrollbarHideTimer = nil
        navButtonHideTimer?.cancel()
        navButtonHideTimer = nil
        chromeAnimationTimer?.cancel()
        chromeAnimationTimer = nil
    }
}
