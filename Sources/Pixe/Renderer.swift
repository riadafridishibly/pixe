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
    weak var window: ImageWindow?

    // View mode
    var mode: ViewMode
    var hasMultipleImages: Bool { imageList.count > 1 }

    // Grid
    let gridLayout = GridLayout()
    var thumbnailCache: ThumbnailCache?
    var backingScaleFactor: CGFloat = 2.0

    // Thumbnail uniform buffer
    private var thumbnailUniformBuffer: MTLBuffer?
    private var thumbnailUniformCapacity: Int = 0

    // Zoom/pan state
    var scale: Float = 1.0
    var translation: SIMD2<Float> = .zero
    var imageAspect: Float = 1.0
    var viewportSize: SIMD2<Float> = SIMD2(800, 600)

    var maxDisplayPixelSize: Int {
        return min(4096, Int(max(viewportSize.x, viewportSize.y)))
    }

    // Image prefetch cache: path → texture
    struct PrefetchEntry {
        let texture: MTLTexture
        let aspect: Float
    }
    private var prefetchCache: [String: PrefetchEntry] = [:]
    private var prefetchLoading: Set<String> = []  // paths currently being loaded (prevents double decode)
    private var currentLoadTask: DispatchWorkItem?
    private var loadGeneration: Int = 0  // increments on each navigation, stale tasks bail out

    init(device: MTLDevice, imageList: ImageList, initialMode: ViewMode, config: Config) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.imageList = imageList
        self.mode = initialMode
        // Conservative default matching 800×600 window at 2× scale.
        // The real drawable size arrives via mtkView(_:drawableSizeWillChange:).
        self.viewportSize = SIMD2(1600, 1200)
        super.init()
        setupPipeline()
        setupVertexBuffer()
        setupSampler()

        if hasMultipleImages {
            thumbnailCache = ThumbnailCache(device: device, config: config)
            gridLayout.totalItems = imageList.count
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
            Vertex(position: SIMD2( 1, -1), texCoord: SIMD2(1, 1)),
            Vertex(position: SIMD2(-1,  1), texCoord: SIMD2(0, 0)),
            Vertex(position: SIMD2( 1, -1), texCoord: SIMD2(1, 1)),
            Vertex(position: SIMD2( 1,  1), texCoord: SIMD2(1, 0)),
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
        if let cached = prefetchCache[path] {
            currentTexture = cached.texture
            imageAspect = cached.aspect
            resetView()
            updateWindowTitle()
            if let view = window?.contentView as? MTKView { view.needsDisplay = true }
            prefetchAdjacentImages()
            return
        }

        // 2. If a display decode is already in flight for this path, wait for it
        if prefetchLoading.contains(path) {
            return
        }

        // 3. Show thumbnail immediately as placeholder (if available)
        if let thumbTex = thumbnailCache?.texture(at: imageList.currentIndex) {
            currentTexture = thumbTex
            imageAspect = thumbnailCache?.aspect(at: imageList.currentIndex) ?? Float(thumbTex.width) / Float(thumbTex.height)
            resetView()
            updateWindowTitle()
            if let view = window?.contentView as? MTKView { view.needsDisplay = true }
        }

        // 3. Background decode at display resolution
        // Mark path as loading so prefetchAdjacentImages won't duplicate this decode
        prefetchLoading.insert(path)

        let device = self.device
        let commandQueue = self.commandQueue
        let maxPixelSize = self.maxDisplayPixelSize

        let task = DispatchWorkItem { [weak self] in
            // Check generation: if user navigated away, this decode is stale
            guard let self = self, self.loadGeneration == generation else {
                DispatchQueue.main.async { [weak self] in self?.prefetchLoading.remove(path) }
                return
            }
            MemoryProfiler.logEvent("display decode starting: \((path as NSString).lastPathComponent)", device: device)
            let texture = ImageLoader.loadDisplayTexture(from: path, device: device, commandQueue: commandQueue, maxPixelSize: maxPixelSize)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.prefetchLoading.remove(path)
                guard self.mode == .image, self.imageList.currentPath == path else { return }
                if let texture = texture {
                    self.currentTexture = texture
                    self.imageAspect = Float(texture.width) / Float(texture.height)
                    self.prefetchCache[path] = PrefetchEntry(texture: texture, aspect: self.imageAspect)
                    MemoryProfiler.logEvent("display decode done → prefetch [\(self.prefetchCache.count) entries]", device: device)
                }
                self.resetView()
                self.updateWindowTitle()
                self.prefetchAdjacentImages()
                if let view = self.window?.contentView as? MTKView { view.needsDisplay = true }
            }
        }
        currentLoadTask = task
        DispatchQueue.global(qos: .userInitiated).async(execute: task)
    }

    private func prefetchAdjacentImages() {
        let currentIdx = imageList.currentIndex
        let count = imageList.count
        guard count > 1 else { return }

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
                MemoryProfiler.logEvent("prefetch evict: \((key as NSString).lastPathComponent) [\(MemoryProfiler.formatBytes(size))]", device: device)
            }
            prefetchCache.removeValue(forKey: key)
        }

        let device = self.device
        let commandQueue = self.commandQueue
        let maxPixelSize = self.maxDisplayPixelSize

        for idx in adjacentIndices {
            let path = imageList.allPaths[idx]
            guard prefetchCache[path] == nil, !prefetchLoading.contains(path) else { continue }
            prefetchLoading.insert(path)

            DispatchQueue.global(qos: .utility).async { [weak self] in
                let texture = ImageLoader.loadDisplayTexture(from: path, device: device, commandQueue: commandQueue, maxPixelSize: maxPixelSize)
                guard let tex = texture else {
                    DispatchQueue.main.async { self?.prefetchLoading.remove(path) }
                    return
                }
                let aspect = Float(tex.width) / Float(tex.height)
                DispatchQueue.main.async {
                    self?.prefetchLoading.remove(path)
                    guard self?.mode == .image else { return }
                    self?.prefetchCache[path] = PrefetchEntry(texture: tex, aspect: aspect)
                }
            }
        }
    }

    func resetView() {
        scale = 1.0
        translation = .zero
    }

    func updateWindowTitle() {
        switch mode {
        case .image:
            guard let path = imageList.currentPath else { return }
            let filename = (path as NSString).lastPathComponent
            window?.updateTitle(filename: filename, index: imageList.currentIndex, total: imageList.count)
        case .thumbnail:
            window?.title = "pixe [\(imageList.count) images]"
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

        var currentInfo: String? = nil
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
        switch mode {
        case .thumbnail:
            guard !imageList.allPaths.isEmpty else { return }
            let index = gridLayout.selectedIndex
            let path = imageList.allPaths[min(index, imageList.allPaths.count - 1)]
            let dir = shortenPath((path as NSString).deletingLastPathComponent)
            window?.updateInfo("\(dir) \u{2014} \(imageList.count) images")
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

            // Grow uniform buffer if needed
            if needed > thumbnailUniformCapacity {
                let newCapacity = max(needed, thumbnailUniformCapacity * 2, 64)
                thumbnailUniformBuffer = device.makeBuffer(length: uniformStride * newCapacity, options: .storageModeShared)
                thumbnailUniformCapacity = newCapacity
            }

            if let buffer = thumbnailUniformBuffer {
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
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        // Trigger background loading for prefetch range
        let prefetch = gridLayout.prefetchRange()
        cache.ensureLoaded(indices: prefetch, paths: imageList.allPaths) { [weak self] in
            if let view = self?.window?.contentView as? MTKView {
                view.needsDisplay = true
            }
        }
    }
}
