import AppKit
import MetalKit
import simd

enum ViewMode {
    case thumbnail
    case image
}

struct Uniforms {
    var transform: simd_float4x4
}

struct ColorUniforms {
    var color: SIMD4<Float>
}

struct Vertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var pipelineState: MTLRenderPipelineState!
    var flatColorPipelineState: MTLRenderPipelineState!
    var samplerState: MTLSamplerState!
    var vertexBuffer: MTLBuffer!

    var currentTexture: MTLTexture?
    let imageList: ImageList
    let config: Config
    weak var window: ImageWindow?

    // View mode
    var mode: ViewMode
    var hasMultipleImages: Bool {
        imageList.count > 1 || imageList.isEnumerating || imageList.isSorting || imageList.hasDirectoryArguments
    }

    // Grid
    let gridLayout = GridLayout()
    var thumbnailCache: ThumbnailCache?
    var backingScaleFactor: CGFloat = 2.0

    // Thumbnail uniform buffer
    private let thumbnailFramesInFlight = 3
    private let thumbnailInFlightSemaphore = DispatchSemaphore(value: 3)
    private var thumbnailUniformBuffers: [MTLBuffer] = []
    private var thumbnailUniformCapacity: Int = 0
    private var thumbnailFrameSlot: Int = 0

    // Zoom/pan state
    var scale: Float = 1.0
    var translation: SIMD2<Float> = .zero
    var imageAspect: Float = 1.0
    var viewportSize: SIMD2<Float> = SIMD2(800, 600)

    var maxDisplayPixelSize: Int {
        return min(4096, Int(max(viewportSize.x, viewportSize.y)))
    }

    var prefetchDisplayPixelSize: Int {
        return max(512, min(maxDisplayPixelSize, 2048))
    }

    // Image prefetch cache: path → texture
    enum DisplayTextureQuality {
        case prefetch
        case full
    }

    struct PrefetchEntry {
        let texture: MTLTexture
        let aspect: Float
        let quality: DisplayTextureQuality
    }

    private var prefetchCache: [String: PrefetchEntry] = [:]
    private var prefetchLoading: Set<String> = []  // paths currently being loaded (prevents double decode)
    private var currentLoadTask: DispatchWorkItem?
    private var loadGeneration: Int = 0  // increments on each navigation, stale tasks bail out
    private var prefetchGeneration: Int = 0  // increments whenever adjacency set changes
    private var thumbnailSearchQuery: String?
    private let displayDecodeQueue = DispatchQueue(label: "pixe.display-decode", qos: .userInitiated)
    private let prefetchDecodeQueue = DispatchQueue(label: "pixe.prefetch-decode", qos: .utility, attributes: .concurrent)
    private let prefetchDecodeSemaphore = DispatchSemaphore(value: 1)

    init(device: MTLDevice, imageList: ImageList, initialMode: ViewMode, config: Config) {
        self.device = device
        commandQueue = device.makeCommandQueue()!
        self.imageList = imageList
        self.config = config
        mode = initialMode
        // Conservative default matching 800×600 window at 2× scale.
        // The real drawable size arrives via mtkView(_:drawableSizeWillChange:).
        viewportSize = SIMD2(1600, 1200)
        super.init()
        setupPipeline()
        setupVertexBuffer()
        setupSampler()

        if hasMultipleImages || imageList.hasDirectoryArguments {
            thumbnailCache = ThumbnailCache(device: device, config: config)
            gridLayout.totalItems = imageList.count
        }

        setupEnumerationCallbacks()
    }

    private func setupEnumerationCallbacks() {
        imageList.onBatchAdded = { [weak self] totalCount in
            guard let self = self else { return }
            self.gridLayout.totalItems = totalCount
            if self.thumbnailCache == nil {
                self.thumbnailCache = ThumbnailCache(device: self.device, config: self.config)
            }
            self.updateWindowTitle()
            if let view = self.window?.contentView as? MTKView {
                view.needsDisplay = true
            }
        }

        imageList.onEnumerationComplete = { [weak self] totalCount in
            guard let self = self else { return }
            if totalCount == 0 && self.imageList.isEmpty {
                NSApp.terminate(nil)
                return
            }
            if totalCount == 1 && self.imageList.count == 1 {
                self.enterImageMode(at: 0)
                return
            }
            // Sort changed indices — invalidate thumbnail cache
            self.thumbnailCache?.invalidateAll()
            self.gridLayout.totalItems = self.imageList.count
            self.gridLayout.clampScroll()
            self.updateWindowTitle()
            if let view = self.window?.contentView as? MTKView {
                view.needsDisplay = true
            }
        }
    }

    private func setupPipeline() {
        let library = try! device.makeLibrary(source: ShaderSource.metalSource, options: nil)
        let vertexFunction = library.makeFunction(name: "vertexShader")!
        let fragmentFunction = library.makeFunction(name: "fragmentShader")!
        let flatColorFunction = library.makeFunction(name: "flatColorFragment")!

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride

        // Textured pipeline
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        // Flat color pipeline
        let flatPipelineDescriptor = MTLRenderPipelineDescriptor()
        flatPipelineDescriptor.vertexFunction = vertexFunction
        flatPipelineDescriptor.fragmentFunction = flatColorFunction
        flatPipelineDescriptor.vertexDescriptor = vertexDescriptor
        flatPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        flatColorPipelineState = try! device.makeRenderPipelineState(descriptor: flatPipelineDescriptor)
    }

    private func setupVertexBuffer() {
        let vertices: [Vertex] = [
            Vertex(position: SIMD2(-1,  1), texCoord: SIMD2(0, 0)),
            Vertex(position: SIMD2(-1, -1), texCoord: SIMD2(0, 1)),
            Vertex(position: SIMD2(1, -1), texCoord: SIMD2(1, 1)),
            Vertex(position: SIMD2(-1,  1), texCoord: SIMD2(0, 0)),
            Vertex(position: SIMD2(1, -1), texCoord: SIMD2(1, 1)),
            Vertex(position: SIMD2(1,  1), texCoord: SIMD2(1, 0))
        ]
        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<Vertex>.stride * vertices.count,
            options: .storageModeShared
        )
    }

    private func setupSampler() {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear  // Enable mipmap filtering
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        samplerState = device.makeSamplerState(descriptor: descriptor)
    }

    // MARK: - Transform

    func buildTransformMatrix() -> simd_float4x4 {
        let viewAspect = viewportSize.x / viewportSize.y

        var sx: Float = 1.0
        var sy: Float = 1.0
        if imageAspect > viewAspect {
            sy = viewAspect / imageAspect
        } else {
            sx = imageAspect / viewAspect
        }

        sx *= scale
        sy *= scale

        let tx = translation.x
        let ty = translation.y

        return simd_float4x4(
            SIMD4<Float>(sx, 0,  0, 0),
            SIMD4<Float>(0,  sy, 0, 0),
            SIMD4<Float>(0,  0,  1, 0),
            SIMD4<Float>(tx, ty, 0, 1)
        )
    }

    // MARK: - Image Loading with Prefetch & Cancellation

    func loadCurrentImage() {
        guard let path = imageList.currentPath else { return }
        currentLoadTask?.cancel()
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
        // Prefetch completion now promotes it to currentTexture when this path is selected.
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
        let rawPreviewMinLongSide = max(1536, Int(Double(maxPixelSize) * 0.9))

        var task: DispatchWorkItem!
        task = DispatchWorkItem { [weak self] in
            // Check generation: if user navigated away, this decode is stale
            guard let self = self, !task.isCancelled, self.loadGeneration == generation else {
                DispatchQueue.main.async { [weak self] in self?.prefetchLoading.remove(path) }
                return
            }
            MemoryProfiler.logEvent("display decode starting: \((path as NSString).lastPathComponent)", device: device)
            let texture = ImageLoader.loadDisplayTexture(
                from: path,
                device: device,
                commandQueue: commandQueue,
                maxPixelSize: maxPixelSize,
                minRawPreviewLongSide: rawPreviewMinLongSide
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
            }
        }
        currentLoadTask = task
        displayDecodeQueue.async(execute: task)
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
                    guard self.prefetchGeneration == generation else { return }
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

    func resetView() {
        scale = 1.0
        translation = .zero
    }

    func updateWindowTitle() {
        let isScanning = imageList.isEnumerating
        let isSorting = imageList.isSorting
        switch mode {
        case .image:
            guard let path = imageList.currentPath else { return }
            let filename = (path as NSString).lastPathComponent
            window?.updateTitle(filename: filename, index: imageList.currentIndex, total: imageList.count)
        case .thumbnail:
            if isScanning {
                window?.title = "pixe [\(imageList.count) images] scanning..."
            } else if isSorting {
                window?.title = "pixe [\(imageList.count) images] sorting..."
            } else {
                window?.title = "pixe [\(imageList.count) images]"
            }
        }
        updateInfoBar()
    }

    // MARK: - Memory Profiling

    func generateMemoryReport() {
        var prefetchEntries: [(path: String, size: Int, dims: String)] = []
        for (path, entry) in prefetchCache {
            let size = MemoryProfiler.textureBytes(entry.texture)
            let dims = "\(entry.texture.width)×\(entry.texture.height)"
            prefetchEntries.append((path: path, size: size, dims: dims))
        }

        var thumbCount = 0
        var thumbTotalBytes = 0
        if let cache = thumbnailCache {
            let snapshot = cache.textureSnapshot()
            thumbCount = snapshot.count
            for tex in snapshot {
                thumbTotalBytes += MemoryProfiler.textureBytes(tex)
            }
        }

        var currentInfo: String?
        if let tex = currentTexture {
            currentInfo = MemoryProfiler.textureSummary(tex)
        }

        let report = MemoryProfiler.Report(
            rss: MemoryProfiler.residentMemoryBytes(),
            virtual: MemoryProfiler.virtualMemoryBytes(),
            metalAllocated: MemoryProfiler.metalAllocatedSize(device),
            prefetchEntries: prefetchEntries,
            thumbnailCount: thumbCount,
            thumbnailTotalBytes: thumbTotalBytes,
            currentTextureInfo: currentInfo
        )
        MemoryProfiler.printReport(report)
    }

    func updateInfoBar() {
        hideImageInfo()
        let isScanning = imageList.isEnumerating
        let isSorting = imageList.isSorting
        switch mode {
        case .thumbnail:
            if imageList.allPaths.isEmpty {
                if isScanning {
                    window?.updateInfo("scanning...")
                } else if isSorting {
                    window?.updateInfo("sorting...")
                }
                return
            }
            let index = gridLayout.selectedIndex
            let path = imageList.allPaths[min(index, imageList.allPaths.count - 1)]
            let dir = shortenPath((path as NSString).deletingLastPathComponent)
            let suffix: String
            if isScanning {
                suffix = " scanning..."
            } else if isSorting {
                suffix = " sorting..."
            } else {
                suffix = ""
            }
            var text = "\(dir) \u{2014} \(imageList.count) images\(suffix)"
            if let query = thumbnailSearchQuery {
                text += query.isEmpty ? " \u{2014} /" : " \u{2014} /\(query)"
            }
            window?.updateInfo(text)
        case .image:
            guard let path = imageList.currentPath else { return }
            let filename = (path as NSString).lastPathComponent
            var text = filename
            if let tex = currentTexture {
                text += " \u{2014} \(tex.width) \u{00D7} \(tex.height)"
            }
            text += " \u{2014} [\(imageList.currentIndex + 1)/\(imageList.count)]"
            window?.updateInfo(text)
        }
    }

    func setThumbnailSearchQuery(_ query: String?) {
        thumbnailSearchQuery = query
        updateInfoBar()
    }

    private func shortenPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Reveal in Finder

    func revealInFinder() {
        let path: String?
        switch mode {
        case .thumbnail:
            let index = gridLayout.selectedIndex
            guard index < imageList.allPaths.count else { return }
            path = imageList.allPaths[index]
        case .image:
            path = imageList.currentPath
        }
        guard let filePath = path else { return }
        NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: "")
    }

    // MARK: - Image Info Panel

    func toggleImageInfo() {
        let path: String?
        switch mode {
        case .thumbnail:
            let index = gridLayout.selectedIndex
            guard index < imageList.allPaths.count else { return }
            path = imageList.allPaths[index]
        case .image:
            path = imageList.currentPath
        }
        guard let filePath = path else { return }
        let metadata = ImageLoader.imageMetadata(path: filePath)
        let text = metadata.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        window?.toggleInfoPanel(text)
    }

    func hideImageInfo() {
        window?.hideInfoPanel()
    }

    // MARK: - Delete Image

    func deleteImage(at index: Int) {
        guard index >= 0 && index < imageList.count else { return }
        let path = imageList.allPaths[index]
        guard let window = window else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move to Trash?"
        alert.informativeText = path
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        if let nsImage = NSImage(contentsOfFile: path) {
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
            imageView.image = nsImage
            imageView.imageScaling = .scaleProportionallyUpOrDown
            alert.accessoryView = imageView
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.performDeletion(at: index, path: path)
            }
        }
    }

    private func performDeletion(at index: Int, path: String) {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            let errorAlert = NSAlert()
            errorAlert.alertStyle = .critical
            errorAlert.messageText = "Failed to move to Trash"
            errorAlert.informativeText = error.localizedDescription
            errorAlert.runModal()
            return
        }

        imageList.remove(at: index)

        if imageList.isEmpty {
            NSApp.terminate(nil)
            return
        }

        thumbnailCache?.invalidateAll()
        prefetchCache.removeValue(forKey: path)

        gridLayout.totalItems = imageList.count
        if gridLayout.selectedIndex >= imageList.count {
            gridLayout.selectedIndex = imageList.count - 1
        }

        switch mode {
        case .thumbnail:
            gridLayout.scrollToSelection()
            updateWindowTitle()
            if let view = window?.contentView as? MTKView { view.needsDisplay = true }
        case .image:
            loadCurrentImage()
        }
    }

    // MARK: - Mode Switching

    func enterImageMode(at index: Int) {
        imageList.goTo(index: index)
        mode = .image
        // Pre-set thumbnail as placeholder to avoid black flash
        currentTexture = thumbnailCache?.texture(at: index)
        loadCurrentImage()
        invalidateCursorRects()
    }

    func enterThumbnailMode() {
        guard hasMultipleImages else { return }
        mode = .thumbnail
        gridLayout.selectedIndex = imageList.currentIndex
        currentTexture = nil
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
    }

    func setScale(_ newScale: Float) {
        scale = max(0.1, min(newScale, 50.0))
    }

    func panBy(dx: Float, dy: Float) {
        translation.x += dx
        translation.y += dy
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = SIMD2(Float(size.width), Float(size.height))

        backingScaleFactor = view.window?.backingScaleFactor ?? 2.0
        let pointWidth = Float(size.width) / Float(backingScaleFactor)
        let pointHeight = Float(size.height) / Float(backingScaleFactor)
        gridLayout.viewportWidth = pointWidth
        gridLayout.viewportHeight = pointHeight
        gridLayout.clampScroll()
    }

    func draw(in view: MTKView) {
        switch mode {
        case .image:
            drawImage(in: view)
        case .thumbnail:
            drawThumbnailGrid(in: view)
        }
    }

    // MARK: - Image Drawing

    private func drawImage(in view: MTKView) {
        guard let texture = currentTexture,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else { return }

        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)
        descriptor.colorAttachments[0].loadAction = .clear

        var uniforms = Uniforms(transform: buildTransformMatrix())

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Thumbnail Grid Drawing

    private func drawThumbnailGrid(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let cache = thumbnailCache else { return }

        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)
        descriptor.colorAttachments[0].loadAction = .clear

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let visible = gridLayout.visibleRange()

        // Draw selection border
        if visible.contains(gridLayout.selectedIndex) {
            encoder.setRenderPipelineState(flatColorPipelineState)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

            // White outer outline
            var outerTransform = Uniforms(transform: gridLayout.outerHighlightTransformForIndex(gridLayout.selectedIndex))
            encoder.setVertexBytes(&outerTransform, length: MemoryLayout<Uniforms>.stride, index: 1)
            var outerColor = ColorUniforms(color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0))
            encoder.setFragmentBytes(&outerColor, length: MemoryLayout<ColorUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

            // Black inner border
            var highlightTransform = Uniforms(transform: gridLayout.highlightTransformForIndex(gridLayout.selectedIndex))
            encoder.setVertexBytes(&highlightTransform, length: MemoryLayout<Uniforms>.stride, index: 1)
            var borderColor = ColorUniforms(color: SIMD4<Float>(0.0, 0.0, 0.0, 1.0))
            encoder.setFragmentBytes(&borderColor, length: MemoryLayout<ColorUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

            // Cell background to create border effect
            var cellTransform = Uniforms(transform: gridLayout.cellTransformForIndex(gridLayout.selectedIndex))
            encoder.setVertexBytes(&cellTransform, length: MemoryLayout<Uniforms>.stride, index: 1)
            var bgColor = ColorUniforms(color: SIMD4<Float>(0.08, 0.08, 0.08, 1.0))
            encoder.setFragmentBytes(&bgColor, length: MemoryLayout<ColorUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        // Draw visible thumbnails — collect uniforms into a shared buffer
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)

        // Gather visible items that have textures
        var visibleItems: [(index: Int, texture: MTLTexture)] = []
        for i in visible {
            guard let texture = cache.texture(at: i) else { continue }
            visibleItems.append((i, texture))
        }

        if !visibleItems.isEmpty {
            let uniformStride = MemoryLayout<Uniforms>.stride
            let needed = visibleItems.count

            // Prevent CPU from rewriting a uniform buffer the GPU is still reading.
            thumbnailInFlightSemaphore.wait()

            if needed > thumbnailUniformCapacity || thumbnailUniformBuffers.count != thumbnailFramesInFlight {
                let newCapacity = max(needed, thumbnailUniformCapacity * 2, 64)
                var newBuffers: [MTLBuffer] = []
                newBuffers.reserveCapacity(thumbnailFramesInFlight)
                for _ in 0 ..< thumbnailFramesInFlight {
                    guard let buffer = device.makeBuffer(length: uniformStride * newCapacity, options: .storageModeShared) else {
                        newBuffers.removeAll()
                        break
                    }
                    newBuffers.append(buffer)
                }
                if newBuffers.count == thumbnailFramesInFlight {
                    thumbnailUniformBuffers = newBuffers
                    thumbnailUniformCapacity = newCapacity
                } else {
                    thumbnailInFlightSemaphore.signal()
                    encoder.endEncoding()
                    commandBuffer.present(drawable)
                    commandBuffer.commit()
                    return
                }
            }

            let frameSlot = thumbnailFrameSlot
            thumbnailFrameSlot = (thumbnailFrameSlot + 1) % thumbnailFramesInFlight
            let buffer = thumbnailUniformBuffers[frameSlot]
            commandBuffer.addCompletedHandler { [thumbnailInFlightSemaphore] _ in
                thumbnailInFlightSemaphore.signal()
            }

            let ptr = buffer.contents().bindMemory(to: Uniforms.self, capacity: needed)
            for (slot, item) in visibleItems.enumerated() {
                let aspect = cache.aspect(at: item.index)
                ptr[slot] = Uniforms(transform: gridLayout.transformForIndex(item.index, imageAspect: aspect))
            }

            for (slot, item) in visibleItems.enumerated() {
                encoder.setVertexBuffer(buffer, offset: uniformStride * slot, index: 1)
                encoder.setFragmentTexture(item.texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        // Trigger background loading for prefetch range
        let prefetch = gridLayout.prefetchRange()
        cache.ensureLoaded(indices: prefetch, pinnedIndices: visible, paths: imageList.allPaths) { [weak self] in
            if let view = self?.window?.contentView as? MTKView {
                view.needsDisplay = true
            }
        }
    }
}
