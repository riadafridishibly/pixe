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

enum SelectionEffect: Int32, CaseIterable {
    case rainbow = 0
    case glow = 1
    case solid = 2
    case fire = 3

    func next() -> SelectionEffect {
        let cases = Self.allCases
        return cases[(cases.firstIndex(of: self)! + 1) % cases.count]
    }

    var label: String {
        switch self {
        case .rainbow: return "rainbow"
        case .glow: return "glow"
        case .solid: return "solid"
        case .fire: return "fire"
        }
    }
}

struct SelectionUniforms {
    var time: Float
    var rectSize: SIMD2<Float>
    var borderWidth: Float
    var effectType: Int32
    var innerOffset: SIMD2<Float>   // offset to inner (thumbnail) rect within expanded quad
    var innerSize: SIMD2<Float>     // size of the inner (thumbnail) rect
}

enum MorphEffect: Int32, CaseIterable {
    case wave = 0
    case tvStatic = 1

    func next() -> MorphEffect {
        let cases = Self.allCases
        return cases[(cases.firstIndex(of: self)! + 1) % cases.count]
    }

    var label: String {
        switch self {
        case .wave: return "wave"
        case .tvStatic: return "tv-static"
        }
    }
}

struct MorphUniforms {
    var time: Float
    var effectType: Int32
}

struct NavZoneUniforms {
    var alpha: Float
    var pointsLeft: Int32
    var aspectRatio: Float
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
    var selectionPipelineState: MTLRenderPipelineState!
    var morphThumbnailPipelineState: MTLRenderPipelineState!
    var navZonePipelineState: MTLRenderPipelineState!
    var samplerState: MTLSamplerState!
    var vertexBuffer: MTLBuffer!

    var currentTexture: MTLTexture?
    var gifAnimator: GIFAnimator?
    private var thumbnailGIFAnimator: GIFAnimator?
    private var thumbnailGIFPath: String?
    let imageList: ImageList
    let config: Config
    weak var window: ImageWindow?

    // View mode
    var mode: ViewMode
    var hasMultipleImages: Bool {
        imageList.count > 1 || imageList.isEnumerating || imageList.isSorting || imageList.hasDirectoryArguments
    }

    // Grid
    let gridLayout: GridLayout
    var thumbnailCache: ThumbnailCache?
    private let aspectPreloadQueue = DispatchQueue(label: "pixe.aspect-preload", qos: .userInitiated)
    private var aspectPreloadGeneration = 0
    private var aspectPreloadedCount = 0
    var backingScaleFactor: CGFloat = 2.0
    var selectionEffect: SelectionEffect = .rainbow
    var morphEffect: MorphEffect = .tvStatic
    private var selectionAnimationStart: CFTimeInterval = CACurrentMediaTime()
    private var selectionAnimationTimer: DispatchSourceTimer?

    // Thumbnail uniform buffer
    private let thumbnailFramesInFlight = 3
    private let thumbnailInFlightSemaphore = DispatchSemaphore(value: 3)
    private var thumbnailUniformBuffers: [MTLBuffer] = []
    private var thumbnailUniformCapacity: Int = 0
    private var thumbnailFrameSlot: Int = 0

    // Zoom/pan state
    var scale: Float = 1.0
    var translation: SIMD2<Float> = .zero
    var rotationSteps: Int = 0  // 0–3, each step = 90° CW
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

    var prefetchCache: [String: PrefetchEntry] = [:]
    var prefetchLoading: Set<String> = []  // paths currently being loaded (prevents double decode)
    private var currentLoadTask: DispatchWorkItem?
    private var currentLoadPath: String?
    var loadGeneration: Int = 0  // increments on each navigation, stale tasks bail out
    var prefetchGeneration: Int = 0  // increments whenever adjacency set changes
    private var thumbnailSearchQuery: String?
    private var infoRestoreWorkItem: DispatchWorkItem?
    private var autoplayTimer: DispatchSourceTimer?
    private var startupAutoplayPending: Bool = false
    private var autoplayInterval: TimeInterval = 3.0
    var isAutoplayActive: Bool { autoplayTimer != nil }
    // Strip animation state
    private var stripOffset: Float = 0        // current animated offset in NDC (0 = centered)
    private var stripAnimationTimer: DispatchSourceTimer?
    private var stripAnimationStartTime: CFTimeInterval = 0
    private var stripAnimationFrom: Float = 0
    private let stripAnimationDuration: TimeInterval = 0.25
    private var isStripAnimating: Bool { stripAnimationTimer != nil }

    // Smooth scroll state
    private var scrollTarget: Float = 0.0
    private var scrollAnimationTimer: DispatchSourceTimer?

    // Chrome overlay state
    private var chromeScrollbarAlpha: Float = 0.0
    private var chromeNavButtonAlpha: Float = 0.0
    private var chromeScrollbarTarget: Float = 0.0
    private var chromeNavButtonTarget: Float = 0.0
    private var chromeAnimationTimer: DispatchSourceTimer?
    private var scrollbarHideTimer: DispatchSourceTimer?
    private var navButtonHideTimer: DispatchSourceTimer?

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
        autoplayInterval = config.autoplayInterval
        if let displaySize = config.thumbDisplaySize {
            gridLayout = GridLayout(defaultSize: Float(displaySize))
        } else {
            gridLayout = GridLayout()
        }
        gridLayout.padding = config.gap
        if let name = config.selectionEffect,
           let effect = SelectionEffect.allCases.first(where: { $0.label == name }) {
            selectionEffect = effect
        }
        super.init()
        setupPipeline()
        setupVertexBuffer()
        setupSampler()

        if hasMultipleImages || imageList.hasDirectoryArguments {
            thumbnailCache = ThumbnailCache(device: device, config: config)
            gridLayout.totalItems = imageList.count
            preloadAspectsAsync()
        }

        if mode == .thumbnail {
            startSelectionAnimation()
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
            self.preloadAspectsAsync()
            self.updateWindowTitle()
            self.startPendingAutoplayIfPossible()
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
            self.thumbnailGIFAnimator?.stop()
            self.thumbnailGIFAnimator = nil
            self.thumbnailGIFPath = nil
            self.thumbnailCache?.invalidateAll()
            self.gridLayout.resetAspects()
            self.aspectPreloadedCount = 0
            self.gridLayout.totalItems = self.imageList.count
            self.gridLayout.clampScroll()
            self.preloadAspectsAsync(from: 0)
            self.updateWindowTitle()
            self.startPendingAutoplayIfPossible()
            if let view = self.window?.contentView as? MTKView {
                view.needsDisplay = true
            }
        }
    }

    /// Preload aspect ratios on a background thread so the layout is stable
    /// before thumbnails appear. Only processes paths added since the last call.
    private func preloadAspectsAsync(from startIndex: Int? = nil) {
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

        // Flat color pipeline (with alpha blending for chrome overlays)
        let flatPipelineDescriptor = MTLRenderPipelineDescriptor()
        flatPipelineDescriptor.vertexFunction = vertexFunction
        flatPipelineDescriptor.fragmentFunction = flatColorFunction
        flatPipelineDescriptor.vertexDescriptor = vertexDescriptor
        flatPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        flatPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        flatPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        flatPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        flatPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        flatPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        flatColorPipelineState = try! device.makeRenderPipelineState(descriptor: flatPipelineDescriptor)

        // Selection border pipeline (animated)
        let selectionFunction = library.makeFunction(name: "selectionFragment")!
        let selPipelineDescriptor = MTLRenderPipelineDescriptor()
        selPipelineDescriptor.vertexFunction = vertexFunction
        selPipelineDescriptor.fragmentFunction = selectionFunction
        selPipelineDescriptor.vertexDescriptor = vertexDescriptor
        selPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        selPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        selPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        selPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        selPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        selPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        selectionPipelineState = try! device.makeRenderPipelineState(descriptor: selPipelineDescriptor)

        // Morph thumbnail pipeline (animated texture effect on selected item)
        let morphFunction = library.makeFunction(name: "morphThumbnailFragment")!
        let morphPipelineDescriptor = MTLRenderPipelineDescriptor()
        morphPipelineDescriptor.vertexFunction = vertexFunction
        morphPipelineDescriptor.fragmentFunction = morphFunction
        morphPipelineDescriptor.vertexDescriptor = vertexDescriptor
        morphPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        morphPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        morphPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        morphPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        morphPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        morphPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        morphThumbnailPipelineState = try! device.makeRenderPipelineState(descriptor: morphPipelineDescriptor)

        // Nav zone pipeline (gradient + chevron overlay for image mode navigation)
        let navZoneFunction = library.makeFunction(name: "navZoneFragment")!
        let navPipelineDescriptor = MTLRenderPipelineDescriptor()
        navPipelineDescriptor.vertexFunction = vertexFunction
        navPipelineDescriptor.fragmentFunction = navZoneFunction
        navPipelineDescriptor.vertexDescriptor = vertexDescriptor
        navPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        navPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        navPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        navPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        navPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        navPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        navZonePipelineState = try! device.makeRenderPipelineState(descriptor: navPipelineDescriptor)
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

        // For 90°/270° rotations the image dimensions are swapped,
        // so fit against the flipped aspect ratio.
        let isOddRotation = (rotationSteps % 2) != 0
        let fittingAspect = isOddRotation ? (1.0 / imageAspect) : imageAspect

        var sx: Float = 1.0
        var sy: Float = 1.0
        if fittingAspect > viewAspect {
            sy = viewAspect / fittingAspect
        } else {
            sx = fittingAspect / viewAspect
        }

        sx *= scale
        sy *= scale

        // 2D rotation matrix components
        let angle = Float(rotationSteps) * (.pi / 2.0)
        let cosA = cos(angle)
        let sinA = sin(angle)

        let tx = translation.x
        let ty = translation.y

        // Compose: S * R (rotate quad first, then scale to fit viewport)
        return simd_float4x4(
            SIMD4<Float>( sx * cosA, -sy * sinA, 0, 0),
            SIMD4<Float>( sx * sinA,  sy * cosA, 0, 0),
            SIMD4<Float>( 0,          0,         1, 0),
            SIMD4<Float>( tx,         ty,        0, 1)
        )
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

    private func updateThumbnailGIFIfNeeded() {
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

    func resetView() {
        scale = 1.0
        translation = .zero
        rotationSteps = 0
    }

    func rotateCW() {
        rotationSteps = (rotationSteps + 1) % 4
        if rotationSteps != 0 { finishStripAnimation() }
    }

    // MARK: - Strip Animation

    /// NDC width of an image fitted to the viewport (preserving aspect ratio).
    private func ndcWidth(forAspect aspect: Float) -> Float {
        let viewAspect = viewportSize.x / viewportSize.y
        return aspect > viewAspect ? 2.0 : 2.0 * aspect / viewAspect
    }

    /// Aspect ratio for any image index (prefetch cache → thumbnail cache → fallback).
    private func aspectForIndex(_ idx: Int) -> Float {
        let path = imageList.allPaths[idx]
        if let entry = prefetchCache[path] { return entry.aspect }
        if let a = thumbnailCache?.aspect(at: idx) { return a }
        return 1.0
    }

    /// Gap between image edges in NDC units.
    private var stripGapNDC: Float {
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

    private func finishStripAnimation() {
        stripAnimationTimer?.cancel()
        stripAnimationTimer = nil
        stripOffset = 0
        if let view = window?.contentView as? MTKView {
            view.needsDisplay = true
        }
    }

    private func buildStripImageTransform(aspect: Float, offsetX: Float) -> simd_float4x4 {
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
            let suffix: String
            if isScanning {
                suffix = " scanning..."
            } else if isSorting {
                suffix = " sorting..."
            } else {
                suffix = ""
            }
            var text: String
            if let query = thumbnailSearchQuery {
                text = query.isEmpty ? "/" : "/\(query)"
            } else {
                let totalWidth = String(imageList.count).count
                let padded = String(repeating: " ", count: totalWidth - String(index + 1).count) + "\(index + 1)"
                text = "[\(padded)/\(imageList.count)]\(suffix) \(shortenPath(path))"
            }
            if imageList.isShuffled { text += " [shuffle]" }
            window?.updateInfo(text)
        case .image:
            guard let path = imageList.currentPath else { return }
            let totalWidth = String(imageList.count).count
            let padded = String(repeating: " ", count: totalWidth - String(imageList.currentIndex + 1).count) + "\(imageList.currentIndex + 1)"
            var text = "[\(padded)/\(imageList.count)] \(path)"
            if let tex = currentTexture {
                text += " \u{2014} \(tex.width) \u{00D7} \(tex.height)"
            }
            if imageList.isShuffled { text += " [shuffle]" }
            if isAutoplayActive { text += " [autoplay]" }
            window?.updateInfo(text)
        }
        updateThumbnailGIFIfNeeded()
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

        gridLayout.resetAspects()
        aspectPreloadedCount = 0
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

    // MARK: - Clipboard

    func copyCurrentImage() {
        guard let path = currentImagePath() else { return }
        guard let nsImage = NSImage(contentsOfFile: path) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
        showTemporaryInfo("Copied image to clipboard")
    }

    func copyCurrentImagePath() {
        guard let path = currentImagePath() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        showTemporaryInfo("Copied path to clipboard")
    }

    private func currentImagePath() -> String? {
        switch mode {
        case .thumbnail:
            let index = gridLayout.selectedIndex
            guard index < imageList.allPaths.count else { return nil }
            return imageList.allPaths[index]
        case .image:
            return imageList.currentPath
        }
    }

    private func showTemporaryInfo(_ message: String) {
        infoRestoreWorkItem?.cancel()
        window?.updateInfo(message)
        let item = DispatchWorkItem { [weak self] in
            self?.updateInfoBar()
        }
        infoRestoreWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    // MARK: - Shuffle

    func toggleShuffle() {
        if imageList.isShuffled {
            imageList.unshuffle()
        } else {
            imageList.shuffle()
        }
        thumbnailCache?.invalidateAll()
        gridLayout.resetAspects()
        aspectPreloadedCount = 0
        gridLayout.totalItems = imageList.count
        preloadAspectsAsync(from: 0)
        if mode == .thumbnail {
            gridLayout.selectedIndex = imageList.currentIndex
            gridLayout.scrollToSelection()
        }
        prefetchCache.removeAll()
        updateWindowTitle()
        if let view = window?.contentView as? MTKView {
            view.needsDisplay = true
        }
    }

    // MARK: - Ignore Folder

    func ignoreCurrentFolder() {
        let filePath: String?
        let activeIndex: Int
        switch mode {
        case .thumbnail:
            activeIndex = gridLayout.selectedIndex
            guard activeIndex < imageList.allPaths.count else { return }
            filePath = imageList.allPaths[activeIndex]
        case .image:
            activeIndex = imageList.currentIndex
            filePath = imageList.currentPath
        }
        guard let filePath else { return }

        let directory = (filePath as NSString).deletingLastPathComponent
        let dirName = (directory as NSString).lastPathComponent
        let removed = imageList.removePathsInDirectory(directory)
        guard removed > 0 else { return }

        if imageList.isEmpty {
            NSApp.terminate(nil)
            return
        }

        thumbnailCache?.invalidateAll()
        gridLayout.resetAspects()
        aspectPreloadedCount = 0
        gridLayout.totalItems = imageList.count
        preloadAspectsAsync(from: 0)
        prefetchCache.removeAll()

        switch mode {
        case .thumbnail:
            gridLayout.selectedIndex = min(activeIndex, imageList.count - 1)
            gridLayout.scrollToSelection()
        case .image:
            loadCurrentImage()
        }

        updateWindowTitle()
        showTemporaryInfo("Ignored \(dirName)/ (\(removed) images)")
        if let view = window?.contentView as? MTKView {
            view.needsDisplay = true
        }
    }

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

    private func startPendingAutoplayIfPossible() {
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
        resetChrome()
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

    // MARK: - Smooth Scroll

    func smoothScrollBy(delta: Float) {
        scrollTarget = gridLayout.scrollOffset + delta
        // Clamp target to valid range
        let maxScroll = max(0, gridLayout.totalHeight - gridLayout.viewportHeight)
        scrollTarget = max(0, min(scrollTarget, maxScroll))
        startScrollAnimation()
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

    private func stopScrollAnimation() {
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

    private func resetChrome() {
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

    // MARK: - Zoom/Pan

    func zoomBy(factor: Float) {
        scale *= factor
        scale = max(0.1, min(scale, 50.0))
        if scale > 1.0 { finishStripAnimation() }
    }

    func setScale(_ newScale: Float) {
        scale = max(0.1, min(newScale, 50.0))
        if scale > 1.0 { finishStripAnimation() }
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
        guard let currentTex = gifAnimator?.currentTexture ?? currentTexture,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else { return }

        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)
        descriptor.colorAttachments[0].loadAction = .clear

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)

        if config.strip && scale <= 1.0 && rotationSteps == 0 && imageList.count > 1 {
            drawImageStrip(encoder: encoder, currentTexture: currentTex)
        } else {
            var uniforms = Uniforms(transform: buildTransformMatrix())
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(currentTex, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        // Chrome: navigation buttons
        if config.chrome && chromeNavButtonAlpha > 0.01 {
            drawNavButtons(encoder: encoder)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func drawImageStrip(encoder: MTLRenderCommandEncoder, currentTexture: MTLTexture) {
        let count = imageList.count
        let currentIdx = imageList.currentIndex
        let n = 3 // max neighbors on each side
        let slots = 2 * n + 1 // total slots: [-n...n] mapped to [0...2n]
        let gap = stripGapNDC

        // Precompute per-slot data using arrays indexed by (r + n)
        var aspects = [Float](repeating: 1.0, count: slots)
        var widths = [Float](repeating: 0, count: slots)
        var indices = [Int](repeating: 0, count: slots)
        for r in -n...n {
            let idx = ((currentIdx + r) % count + count) % count
            let s = r + n
            indices[s] = idx
            aspects[s] = r == 0 ? imageAspect : aspectForIndex(idx)
            widths[s] = ndcWidth(forAspect: aspects[s])
        }

        // Compute center positions by accumulating widths outward from center
        var centers = [Float](repeating: 0, count: slots)
        centers[n] = stripOffset
        for r in 1...n {
            centers[n + r] = centers[n + r - 1] + widths[n + r - 1] / 2.0 + gap + widths[n + r] / 2.0
            centers[n - r] = centers[n - r + 1] - widths[n - r + 1] / 2.0 - gap - widths[n - r] / 2.0
        }

        for r in -n...n {
            let s = r + n
            let centerX = centers[s]
            let w = widths[s]
            if centerX + w / 2.0 < -1.0 || centerX - w / 2.0 > 1.0 { continue }

            let idx = indices[s]
            // Avoid drawing duplicates when count is small
            if count <= n * 2 && r != 0 {
                let firstR = ((idx - currentIdx) % count + count) % count
                let canonR = firstR <= count / 2 ? firstR : firstR - count
                if canonR != r { continue }
            }

            var texture: MTLTexture
            if r == 0 {
                texture = currentTexture
            } else {
                let path = imageList.allPaths[idx]
                if let entry = prefetchCache[path] {
                    texture = entry.texture
                } else if let thumbTex = thumbnailCache?.texture(at: idx) {
                    texture = thumbTex
                } else {
                    continue
                }
            }

            var uniforms = Uniforms(transform: buildStripImageTransform(aspect: aspects[s], offsetX: centerX))
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
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

        // Sync aspect ratios from cache so layout reflects actual image proportions
        gridLayout.updateAspects(from: cache.aspects)

        let visible = gridLayout.visibleRange()
        let animTime = Float(CACurrentMediaTime() - selectionAnimationStart)

        // Draw visible thumbnails — collect uniforms into a shared buffer
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)

        // Gather visible items that have textures
        var visibleItems: [(index: Int, texture: MTLTexture)] = []
        for i in visible {
            let texture: MTLTexture
            if i == gridLayout.selectedIndex, let animTex = thumbnailGIFAnimator?.currentTexture {
                texture = animTex
            } else {
                guard let t = cache.texture(at: i) else { continue }
                texture = t
            }
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
                ptr[slot] = Uniforms(transform: gridLayout.transformForIndex(item.index))
            }

            let selIdx = gridLayout.selectedIndex
            var selectedSlot: Int? = nil

            // Draw non-selected thumbnails with normal pipeline
            for (slot, item) in visibleItems.enumerated() {
                if item.index == selIdx {
                    selectedSlot = slot
                    continue
                }
                encoder.setVertexBuffer(buffer, offset: uniformStride * slot, index: 1)
                encoder.setFragmentTexture(item.texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }

            // Draw selected thumbnail with morph effect
            if let slot = selectedSlot {
                encoder.setRenderPipelineState(morphThumbnailPipelineState)
                encoder.setFragmentSamplerState(samplerState, index: 0)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(buffer, offset: uniformStride * slot, index: 1)
                encoder.setFragmentTexture(visibleItems[slot].texture, index: 0)
                var morph = MorphUniforms(time: animTime, effectType: morphEffect.rawValue)
                encoder.setFragmentBytes(&morph, length: MemoryLayout<MorphUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        // Draw animated selection border on top of thumbnails
        if visible.contains(gridLayout.selectedIndex) {
            let selIdx = gridLayout.selectedIndex
            let (_, _, itemW, itemH) = gridLayout.itemRect(at: selIdx)
            let borderWidth: Float = 6.0

            encoder.setRenderPipelineState(selectionPipelineState)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

            var transform = Uniforms(transform: gridLayout.transformForIndex(selIdx))
            encoder.setVertexBytes(&transform, length: MemoryLayout<Uniforms>.stride, index: 1)

            let fireInset: Float = selectionEffect == .fire ? 20.0 : 0.0
            var selUniforms = SelectionUniforms(
                time: animTime,
                rectSize: SIMD2<Float>(itemW, itemH),
                borderWidth: borderWidth,
                effectType: selectionEffect.rawValue,
                innerOffset: SIMD2<Float>(fireInset, fireInset),
                innerSize: SIMD2<Float>(itemW - fireInset * 2, itemH - fireInset * 2)
            )
            encoder.setFragmentBytes(&selUniforms, length: MemoryLayout<SelectionUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        // Chrome: hover highlight
        if config.chrome,
           let inputHandler = (view as? MetalImageView)?.inputHandler,
           let hoverIdx = inputHandler.hoveredIndex,
           hoverIdx != gridLayout.selectedIndex,
           visible.contains(hoverIdx) {
            drawHoverHighlight(encoder: encoder, index: hoverIdx)
        }

        // Chrome: scrollbar
        if config.chrome && chromeScrollbarAlpha > 0.01 {
            drawScrollbar(encoder: encoder)
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

    // MARK: - Chrome Drawing

    private func drawHoverHighlight(encoder: MTLRenderCommandEncoder, index: Int) {
        encoder.setRenderPipelineState(flatColorPipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        var transform = Uniforms(transform: gridLayout.transformForIndex(index))
        encoder.setVertexBytes(&transform, length: MemoryLayout<Uniforms>.stride, index: 1)

        var color = ColorUniforms(color: SIMD4<Float>(1, 1, 1, 0.08))
        encoder.setFragmentBytes(&color, length: MemoryLayout<ColorUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawScrollbar(encoder: MTLRenderCommandEncoder) {
        let vpW = gridLayout.viewportWidth
        let vpH = gridLayout.viewportHeight
        let visFrac = gridLayout.visibleFraction
        guard visFrac < 1.0 else { return }  // No scrollbar if everything fits

        let scrollFrac = gridLayout.scrollFraction
        let barWidth: Float = 6.0
        let barPadding: Float = 4.0
        let thumbHeight = max(20.0, vpH * visFrac)
        let trackHeight = vpH - barPadding * 2
        let thumbY = barPadding + scrollFrac * (trackHeight - thumbHeight)

        // Convert to NDC
        let ndcX = ((vpW - barPadding - barWidth / 2.0) / vpW) * 2.0 - 1.0
        let ndcY = 1.0 - ((thumbY + thumbHeight / 2.0) / vpH) * 2.0
        let ndcW = barWidth / vpW
        let ndcH = thumbHeight / vpH

        encoder.setRenderPipelineState(flatColorPipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        let scrollTransform = simd_float4x4(
            SIMD4<Float>(ndcW, 0, 0, 0),
            SIMD4<Float>(0, ndcH, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(ndcX, ndcY, 0, 1)
        )
        var transform = Uniforms(transform: scrollTransform)
        encoder.setVertexBytes(&transform, length: MemoryLayout<Uniforms>.stride, index: 1)

        var color = ColorUniforms(color: SIMD4<Float>(1, 1, 1, chromeScrollbarAlpha))
        encoder.setFragmentBytes(&color, length: MemoryLayout<ColorUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawNavButtons(encoder: MTLRenderCommandEncoder) {
        guard let inputHandler = (window?.contentView as? MetalImageView)?.inputHandler else { return }

        encoder.setRenderPipelineState(navZonePipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        // Full-height zones covering the left/right 15% of the viewport
        let zoneWidth: Float = 0.15  // fraction of viewport — matches click edge zone

        if inputHandler.mouseInLeftEdge {
            drawNavZone(encoder: encoder, ndcLeft: -1.0, ndcWidth: zoneWidth * 2.0, pointsLeft: true)
        }
        if inputHandler.mouseInRightEdge {
            drawNavZone(encoder: encoder, ndcLeft: 1.0 - zoneWidth * 2.0, ndcWidth: zoneWidth * 2.0, pointsLeft: false)
        }
    }

    private func drawNavZone(encoder: MTLRenderCommandEncoder,
                            ndcLeft: Float, ndcWidth: Float, pointsLeft: Bool) {
        // Full-height quad positioned at the edge
        let ndcCenterX = ndcLeft + ndcWidth / 2.0
        let transform = simd_float4x4(
            SIMD4<Float>(ndcWidth / 2.0, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),   // full height in NDC
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(ndcCenterX, 0, 0, 1)
        )
        var uniforms = Uniforms(transform: transform)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)

        let vpW = gridLayout.viewportWidth
        let vpH = gridLayout.viewportHeight
        let zoneWidthPts = vpW * 0.15  // matches the 15% edge zone
        let aspect = zoneWidthPts / vpH

        var nav = NavZoneUniforms(alpha: chromeNavButtonAlpha, pointsLeft: pointsLeft ? 1 : 0, aspectRatio: aspect)
        encoder.setFragmentBytes(&nav, length: MemoryLayout<NavZoneUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
