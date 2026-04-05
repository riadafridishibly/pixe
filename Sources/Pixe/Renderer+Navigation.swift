import AppKit
import MetalKit
import simd

extension Renderer {
    func resetView() {
        scale = 1.0
        translation = .zero
        rotationSteps = 0
        invalidateCursorRects()
    }

    func rotateCW() {
        rotationSteps = (rotationSteps + 1) % 4
        if rotationSteps != 0 { finishStripAnimation() }
    }

    // MARK: - Strip Animation

    private var isStripAnimating: Bool { stripAnimationTimer != nil }

    /// NDC width of an image fitted to the viewport (preserving aspect ratio).
    func ndcWidth(forAspect aspect: Float) -> Float {
        let viewAspect = viewportSize.x / viewportSize.y
        return aspect > viewAspect ? 2.0 : 2.0 * aspect / viewAspect
    }

    /// Aspect ratio for any image index (prefetch cache → thumbnail cache → fallback).
    func aspectForIndex(_ idx: Int) -> Float {
        let path = imageList.allPaths[idx]
        if let entry = prefetchCache[path] { return entry.aspect }
        if let a = thumbnailCache?.aspect(at: idx) { return a }
        return 1.0
    }

    /// Gap between image edges in NDC units.
    var stripGapNDC: Float {
        let viewWidthPts = viewportSize.x / Float(backingScaleFactor)
        return (config.stripGap * 2.0) / viewWidthPts
    }

    /// Center-to-center distance between two adjacent images in NDC.
    private func stripSlotDistance(leftAspect: Float, rightAspect: Float) -> Float {
        return ndcWidth(forAspect: leftAspect) / 2.0 + stripGapNDC + ndcWidth(forAspect: rightAspect) / 2.0
    }

    func navigateWithStripAnimation(direction: Int) {
        guard imageList.count > 1 else { return }

        // If already animating, finish instantly and start a new animation
        if isStripAnimating {
            finishStripAnimation()
        }

        // Compute the distance in NDC between old current and new current BEFORE advancing
        let oldAspect = imageAspect
        let count = imageList.count
        let neighborIdx = direction > 0
            ? (imageList.currentIndex + 1) % count
            : (imageList.currentIndex - 1 + count) % count
        let neighborAspect = aspectForIndex(neighborIdx)
        let dist = stripSlotDistance(leftAspect: oldAspect, rightAspect: neighborAspect)

        // Advance image list
        if direction > 0 {
            imageList.goNext()
        } else {
            imageList.goPrevious()
        }
        loadCurrentImage()

        // Animate stripOffset (NDC units) from starting position to 0 (centered).
        // Navigate next: the old image was at center, new current was to the right,
        // so after advancing, shift the strip right (+dist) and slide back to 0.
        // Navigate prev: opposite direction.
        stripAnimationFrom = direction > 0 ? dist : -dist
        stripOffset = stripAnimationFrom
        stripAnimationStartTime = CACurrentMediaTime()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        timer.setEventHandler { [weak self] in
            self?.updateStripAnimation()
        }
        timer.resume()
        stripAnimationTimer = timer
    }

    private func updateStripAnimation() {
        let elapsed = CACurrentMediaTime() - stripAnimationStartTime
        let progress = min(1.0, Float(elapsed / stripAnimationDuration))

        // Ease-out cubic: 1 - (1 - t)^3
        let eased = 1.0 - pow(1.0 - progress, 3)

        stripOffset = stripAnimationFrom * (1.0 - eased)

        if let view = window?.contentView as? MTKView {
            view.needsDisplay = true
        }

        if progress >= 1.0 {
            finishStripAnimation()
        }
    }

    func finishStripAnimation() {
        stripAnimationTimer?.cancel()
        stripAnimationTimer = nil
        stripOffset = 0
        if let view = window?.contentView as? MTKView {
            view.needsDisplay = true
        }
    }

    func buildStripImageTransform(aspect: Float, offsetX: Float) -> simd_float4x4 {
        let viewAspect = viewportSize.x / viewportSize.y

        var sx: Float = 1.0
        var sy: Float = 1.0
        if aspect > viewAspect {
            sy = viewAspect / aspect
        } else {
            sx = aspect / viewAspect
        }

        return simd_float4x4(
            SIMD4<Float>( sx, 0,  0, 0),
            SIMD4<Float>( 0,  sy, 0, 0),
            SIMD4<Float>( 0,  0,  1, 0),
            SIMD4<Float>( offsetX, 0, 0, 1)
        )
    }

    // MARK: - Mode Switching

    func enterImageMode(at index: Int) {
        thumbnailGIFAnimator?.stop()
        thumbnailGIFAnimator = nil
        thumbnailGIFPath = nil
        stopSelectionAnimation()
        finishStripAnimation()
        stopScrollAnimation()
        resetChrome()
        imageList.goTo(index: index)
        mode = .image
        // Pre-set thumbnail as placeholder to avoid black flash
        currentTexture = thumbnailCache?.texture(at: index)
        loadCurrentImage()
        invalidateCursorRects()
    }

    func enterThumbnailMode() {
        guard hasMultipleImages else { return }
        stopAutoplay()
        finishStripAnimation()
        stopScrollAnimation()
        resetChrome()
        NSCursor.arrow.set()
        mode = .thumbnail
        startSelectionAnimation()
        gridLayout.selectedIndex = imageList.currentIndex
        currentTexture = nil
        gifAnimator?.stop()
        gifAnimator = nil
        thumbnailGIFAnimator?.stop()
        thumbnailGIFAnimator = nil
        thumbnailGIFPath = nil
        currentLoadTask?.cancel()
        loadGeneration += 1
        prefetchGeneration += 1
        let evictedCount = prefetchCache.count
        prefetchCache.removeAll()
        prefetchLoading.removeAll()
        MemoryProfiler.logEvent("enterThumbnailMode: evicted \(evictedCount) prefetch entries", device: device)
        gridLayout.scrollToSelection()
        updateWindowTitle()
        invalidateCursorRects()
        if let view = window?.contentView as? MTKView {
            view.needsDisplay = true
        }
    }

    private func invalidateCursorRects() {
        if let view = window?.contentView {
            window?.invalidateCursorRects(for: view)
        }
    }

    // MARK: - Zoom/Pan

    func zoomBy(factor: Float) {
        scale *= factor
        scale = max(0.1, min(scale, 50.0))
        if scale > 1.0 { finishStripAnimation() }
        invalidateCursorRects()
    }

    func setScale(_ newScale: Float) {
        scale = max(0.1, min(newScale, 50.0))
        if scale > 1.0 { finishStripAnimation() }
        invalidateCursorRects()
    }

    func panBy(dx: Float, dy: Float) {
        translation.x += dx
        translation.y += dy
    }
}
