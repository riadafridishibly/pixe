import AppKit
import MetalKit

extension Renderer {
    /// Preload aspect ratios on a background thread so the layout is stable
    /// before thumbnails appear. Only processes paths added since the last call.
    func preloadAspectsAsync(from startIndex: Int? = nil) {
        let start = startIndex ?? aspectPreloadedCount
        let paths = imageList.allPaths
        guard start < paths.count else { return }
        aspectPreloadedCount = paths.count

        aspectPreloadGeneration += 1
        let generation = aspectPreloadGeneration
        let store = thumbnailCache?.metadataStore
        let slice = Array(paths[start...])

        aspectPreloadQueue.async { [weak self] in
            let cached = store?.bulkCachedDimensions(paths: slice) ?? [:]

            var aspects: [Int: Float] = [:]
            aspects.reserveCapacity(slice.count)
            var newDimensions: [(path: String, width: Int, height: Int)] = []

            for (i, path) in slice.enumerated() {
                if i % 50 == 0, let self = self, self.aspectPreloadGeneration != generation {
                    return
                }
                let dims = cached[path] ?? ImageLoader.imageDimensions(path: path)
                guard let dims = dims else { continue }
                let aspect = Float(dims.width) / max(Float(dims.height), 1.0)
                aspects[start + i] = aspect
                if cached[path] == nil {
                    newDimensions.append((path: path, width: dims.width, height: dims.height))
                }
            }

            if !newDimensions.isEmpty {
                store?.bulkUpsertDimensions(entries: newDimensions)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.aspectPreloadGeneration == generation else { return }
                self.gridLayout.setPreloadedAspects(aspects)
                if let view = self.window?.contentView as? MTKView {
                    view.needsDisplay = true
                }
            }
        }
    }

    // MARK: - Image Loading with Prefetch & Cancellation

    func loadCurrentImage() {
        guard let path = imageList.currentPath else { return }
        currentLoadTask?.cancel()
        gifAnimator?.stop()
        gifAnimator = nil
        // Immediately clean up prefetchLoading for the cancelled task's path
        // so stale entries don't cause the next load to early-return.
        if let oldPath = currentLoadPath {
            prefetchLoading.remove(oldPath)
        }
        currentLoadPath = path
        loadGeneration += 1
        let generation = loadGeneration

        // 1. Check prefetch cache (instant — display-quality)
        var showedPrefetchTexture = false
        if let cached = prefetchCache[path] {
            currentTexture = cached.texture
            imageAspect = cached.aspect
            showedPrefetchTexture = true
            resetView()
            updateWindowTitle()
            if let view = window?.contentView as? MTKView { view.needsDisplay = true }
            if cached.quality == .full {
                prefetchAdjacentImages()
                loadGIFAnimatorIfNeeded(path: path)
                return
            }
        }

        // 2. Show thumbnail immediately as placeholder (if available)
        if !showedPrefetchTexture, let thumbTex = thumbnailCache?.texture(at: imageList.currentIndex) {
            currentTexture = thumbTex
            imageAspect = thumbnailCache?.aspect(at: imageList.currentIndex) ?? Float(thumbTex.width) / Float(thumbTex.height)
            resetView()
            updateWindowTitle()
            if let view = window?.contentView as? MTKView { view.needsDisplay = true }
        }

        // 3. If a decode is already in flight for this path, wait for it to complete.
        // Prefetch completion promotes it to currentTexture when this path is current.
        if prefetchLoading.contains(path) {
            updateWindowTitle()
            return
        }

        // 4. Background decode at display resolution
        // Mark path as loading so prefetchAdjacentImages won't duplicate this decode
        prefetchLoading.insert(path)

        let device = self.device
        let commandQueue = self.commandQueue
        let maxPixelSize = maxDisplayPixelSize
        let hadPrefetch = showedPrefetchTexture

        var task: DispatchWorkItem!
        task = DispatchWorkItem { [weak self] in
            guard let self = self, !task.isCancelled, self.loadGeneration == generation else {
                DispatchQueue.main.async { [weak self] in self?.prefetchLoading.remove(path) }
                return
            }

            let isRaw = ImageLoader.isRawFile(path)

            // Stage 1 (RAW only): show embedded preview before expensive full decode.
            // Skip if prefetch cache already provided a preview.
            if isRaw, !hadPrefetch {
                if let preview = ImageLoader.loadPreviewTexture(
                    from: path, device: device, maxPixelSize: maxPixelSize, minLongSide: 16
                ) {
                    let aspect = Float(preview.width) / Float(preview.height)
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.loadGeneration == generation,
                              self.mode == .image, self.imageList.currentPath == path else { return }
                        if self.prefetchCache[path]?.quality != .full {
                            self.currentTexture = preview
                            self.imageAspect = aspect
                            self.prefetchCache[path] = PrefetchEntry(texture: preview, aspect: aspect, quality: .prefetch)
                            self.resetView()
                            self.updateWindowTitle()
                            self.prefetchAdjacentImages()
                            if let view = self.window?.contentView as? MTKView { view.needsDisplay = true }
                        }
                    }
                }
                // Bail before expensive full RAW decode if user navigated away
                guard !task.isCancelled, self.loadGeneration == generation else {
                    DispatchQueue.main.async { [weak self] in self?.prefetchLoading.remove(path) }
                    return
                }
            }

            // Stage 2: Full quality decode (demosaic + color for RAW, standard for others)
            MemoryProfiler.logEvent("display decode starting: \((path as NSString).lastPathComponent)", device: device)
            let texture = ImageLoader.loadFullQualityTexture(
                from: path, device: device, commandQueue: commandQueue, maxPixelSize: maxPixelSize
            )
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.prefetchLoading.remove(path)
                guard self.mode == .image, self.imageList.currentPath == path else { return }
                if let texture = texture {
                    self.currentTexture = texture
                    self.imageAspect = Float(texture.width) / Float(texture.height)
                    self.prefetchCache[path] = PrefetchEntry(texture: texture, aspect: self.imageAspect, quality: .full)
                    MemoryProfiler.logEvent("display decode done → prefetch [\(self.prefetchCache.count) entries]", device: device)
                }
                self.resetView()
                self.updateWindowTitle()
                self.prefetchAdjacentImages()
                if let view = self.window?.contentView as? MTKView { view.needsDisplay = true }
                self.loadGIFAnimatorIfNeeded(path: path)
            }
        }
        currentLoadTask = task
        displayDecodeQueue.async(execute: task)
    }

    private func loadGIFAnimatorIfNeeded(path: String) {
        guard GIFLoader.isGIF(path) else { return }
        let device = self.device
        let maxPx = self.maxDisplayPixelSize
        displayDecodeQueue.async { [weak self] in
            let animator = GIFLoader.loadAnimatedGIF(from: path, device: device, maxPixelSize: maxPx)
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      self.mode == .image,
                      self.imageList.currentPath == path else { return }
                if let animator = animator {
                    self.gifAnimator = animator
                    self.imageAspect = animator.aspect
                    if let view = self.window?.contentView as? MTKView {
                        animator.start(view: view)
                    }
                }
            }
        }
    }

    func updateThumbnailGIFIfNeeded() {
        guard mode == .thumbnail else { return }
        let index = gridLayout.selectedIndex
        guard index < imageList.allPaths.count else { return }
        let path = imageList.allPaths[index]

        // Already animating this path
        if path == thumbnailGIFPath { return }

        // Stop previous animator
        thumbnailGIFAnimator?.stop()
        thumbnailGIFAnimator = nil
        thumbnailGIFPath = nil

        guard GIFLoader.isGIF(path) else { return }
        thumbnailGIFPath = path

        let device = self.device
        let maxPx = thumbnailCache?.maxPixelSize ?? 256
        displayDecodeQueue.async { [weak self] in
            let animator = GIFLoader.loadAnimatedGIF(from: path, device: device, maxPixelSize: maxPx)
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      self.mode == .thumbnail,
                      self.thumbnailGIFPath == path else { return }
                if let animator = animator {
                    self.thumbnailGIFAnimator = animator
                    if let view = self.window?.contentView as? MTKView {
                        animator.start(view: view)
                    }
                }
            }
        }
    }

    private func currentAndAdjacentPaths() -> Set<String> {
        let count = imageList.count
        guard count > 0 else { return [] }

        let currentIdx = imageList.currentIndex
        if count == 1 {
            return [imageList.allPaths[currentIdx]]
        }

        let adjacentIndices = [
            (currentIdx + 1) % count,
            (currentIdx - 1 + count) % count
        ]
        return Set(([currentIdx] + adjacentIndices).map { imageList.allPaths[$0] })
    }

    private func prefetchAdjacentImages() {
        let currentIdx = imageList.currentIndex
        let count = imageList.count
        guard count > 1 else { return }
        prefetchGeneration += 1
        let generation = prefetchGeneration

        let adjacentIndices = [
            (currentIdx + 1) % count,
            (currentIdx - 1 + count) % count
        ]

        // Evict entries that are no longer adjacent or current
        let keepPaths = Set(
            ([currentIdx] + adjacentIndices).map { imageList.allPaths[$0] }
        )
        for key in prefetchCache.keys where !keepPaths.contains(key) {
            if let entry = prefetchCache[key] {
                let size = MemoryProfiler.textureBytes(entry.texture)
                MemoryProfiler.logEvent(
                    "prefetch evict: \((key as NSString).lastPathComponent) [\(MemoryProfiler.formatBytes(size))]",
                    device: device
                )
            }
            prefetchCache.removeValue(forKey: key)
        }

        let device = self.device
        let commandQueue = self.commandQueue
        let maxPixelSize = prefetchDisplayPixelSize

        for idx in adjacentIndices {
            let path = imageList.allPaths[idx]
            guard prefetchCache[path] == nil, !prefetchLoading.contains(path) else { continue }
            prefetchLoading.insert(path)

            prefetchDecodeQueue.async { [weak self] in
                guard let self = self else { return }
                let shouldStart = DispatchQueue.main.sync { () -> Bool in
                    guard self.mode == .image else {
                        self.prefetchLoading.remove(path)
                        return false
                    }
                    guard self.prefetchGeneration == generation else {
                        self.prefetchLoading.remove(path)
                        return false
                    }
                    guard self.currentAndAdjacentPaths().contains(path) else {
                        self.prefetchLoading.remove(path)
                        return false
                    }
                    return true
                }
                guard shouldStart else { return }

                self.prefetchDecodeSemaphore.wait()
                defer { self.prefetchDecodeSemaphore.signal() }

                let shouldContinue = DispatchQueue.main.sync { () -> Bool in
                    guard self.mode == .image else {
                        self.prefetchLoading.remove(path)
                        return false
                    }
                    guard self.prefetchGeneration == generation else {
                        self.prefetchLoading.remove(path)
                        return false
                    }
                    guard self.currentAndAdjacentPaths().contains(path) else {
                        self.prefetchLoading.remove(path)
                        return false
                    }
                    return true
                }
                guard shouldContinue else { return }

                let texture = ImageLoader.loadDisplayTexture(
                    from: path,
                    device: device,
                    commandQueue: commandQueue,
                    maxPixelSize: maxPixelSize,
                    minRawPreviewLongSide: 16
                )
                guard let tex = texture else {
                    DispatchQueue.main.async { self.prefetchLoading.remove(path) }
                    return
                }
                let aspect = Float(tex.width) / Float(tex.height)
                DispatchQueue.main.async {
                    self.prefetchLoading.remove(path)
                    guard self.mode == .image else { return }
                    guard self.prefetchGeneration == generation else {
                        // Generation changed — loadCurrentImage() may have early-returned
                        // relying on this prefetch to promote the texture. Re-trigger loading
                        // so the image doesn't get stuck on the thumbnail placeholder.
                        if self.imageList.currentPath == path {
                            self.loadCurrentImage()
                        }
                        return
                    }
                    guard self.currentAndAdjacentPaths().contains(path) else { return }
                    self.prefetchCache[path] = PrefetchEntry(texture: tex, aspect: aspect, quality: .prefetch)

                    // If user navigated to this image while prefetch was in-flight,
                    // promote the prefetched texture immediately.
                    guard self.imageList.currentPath == path else { return }
                    self.currentTexture = tex
                    self.imageAspect = aspect
                    self.resetView()
                    self.updateWindowTitle()
                    if let view = self.window?.contentView as? MTKView {
                        view.needsDisplay = true
                    }
                    // Upgrade this prefetched texture to full display quality in background.
                    self.loadCurrentImage()
                }
            }
        }
    }
}
