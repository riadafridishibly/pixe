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
    var thumbnailGIFAnimator: GIFAnimator?
    var thumbnailGIFPath: String?
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
    let aspectPreloadQueue = DispatchQueue(label: "pixe.aspect-preload", qos: .userInitiated)
    var aspectPreloadGeneration = 0
    var aspectPreloadedCount = 0
    var backingScaleFactor: CGFloat = 2.0
    var selectionEffect: SelectionEffect = .rainbow
    var morphEffect: MorphEffect = .tvStatic
    var selectionAnimationStart: CFTimeInterval = CACurrentMediaTime()
    var selectionAnimationTimer: DispatchSourceTimer?

    // Thumbnail uniform buffer
    let thumbnailFramesInFlight = 3
    let thumbnailInFlightSemaphore = DispatchSemaphore(value: 3)
    var thumbnailUniformBuffers: [MTLBuffer] = []
    var thumbnailUniformCapacity: Int = 0
    var thumbnailFrameSlot: Int = 0

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
    var currentLoadTask: DispatchWorkItem?
    var currentLoadPath: String?
    var loadGeneration: Int = 0  // increments on each navigation, stale tasks bail out
    var prefetchGeneration: Int = 0  // increments whenever adjacency set changes
    var thumbnailSearchQuery: String?
    var infoRestoreWorkItem: DispatchWorkItem?
    var autoplayTimer: DispatchSourceTimer?
    var startupAutoplayPending: Bool = false
    var autoplayInterval: TimeInterval = 3.0
    var isAutoplayActive: Bool { autoplayTimer != nil }
    // Strip animation state
    var stripOffset: Float = 0        // current animated offset in NDC (0 = centered)
    var stripAnimationTimer: DispatchSourceTimer?
    var stripAnimationStartTime: CFTimeInterval = 0
    var stripAnimationFrom: Float = 0
    let stripAnimationDuration: TimeInterval = 0.25

    // Smooth scroll state
    var scrollTarget: Float = 0.0
    var scrollAnimationTimer: DispatchSourceTimer?

    // Chrome overlay state
    var chromeScrollbarAlpha: Float = 0.0
    var chromeNavButtonAlpha: Float = 0.0
    var chromeScrollbarTarget: Float = 0.0
    var chromeNavButtonTarget: Float = 0.0
    var chromeAnimationTimer: DispatchSourceTimer?
    var scrollbarHideTimer: DispatchSourceTimer?
    var navButtonHideTimer: DispatchSourceTimer?

    let displayDecodeQueue = DispatchQueue(label: "pixe.display-decode", qos: .userInitiated)
    let prefetchDecodeQueue = DispatchQueue(label: "pixe.prefetch-decode", qos: .utility, attributes: .concurrent)
    let prefetchDecodeSemaphore = DispatchSemaphore(value: 1)

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
        gridLayout.gap = config.gap
        gridLayout.padding = config.padding
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
}
