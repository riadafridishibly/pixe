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
    let hasMultipleImages: Bool

    // Grid
    let gridLayout = GridLayout()
    var thumbnailCache: ThumbnailCache?
    var backingScaleFactor: CGFloat = 2.0

    // Zoom/pan state
    var scale: Float = 1.0
    var translation: SIMD2<Float> = .zero
    var imageAspect: Float = 1.0
    var viewportSize: SIMD2<Float> = SIMD2(800, 600)

    init(device: MTLDevice, imageList: ImageList, initialMode: ViewMode) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.imageList = imageList
        self.mode = initialMode
        self.hasMultipleImages = imageList.count > 1
        super.init()
        setupPipeline()
        setupVertexBuffer()
        setupSampler()

        if hasMultipleImages {
            thumbnailCache = ThumbnailCache(device: device)
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
        descriptor.mipFilter = .notMipmapped
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

    // MARK: - Image Loading

    func loadCurrentImage() {
        guard let path = imageList.currentPath else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let texture = ImageLoader.loadTexture(from: path, device: self.device)
            DispatchQueue.main.async {
                self.currentTexture = texture
                if let texture = texture {
                    self.imageAspect = Float(texture.width) / Float(texture.height)
                }
                self.resetView()
                self.updateWindowTitle()
                if let view = self.window?.contentView as? MTKView {
                    view.needsDisplay = true
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
    }

    // MARK: - Mode Switching

    func enterImageMode(at index: Int) {
        imageList.goTo(index: index)
        mode = .image
        currentTexture = nil
        loadCurrentImage()
    }

    func enterThumbnailMode() {
        guard hasMultipleImages else { return }
        mode = .thumbnail
        gridLayout.selectedIndex = imageList.currentIndex
        currentTexture = nil
        gridLayout.scrollToSelection()
        updateWindowTitle()
        if let view = window?.contentView as? MTKView {
            view.needsDisplay = true
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

            // Outer border quad (blue)
            var highlightTransform = Uniforms(transform: gridLayout.highlightTransformForIndex(gridLayout.selectedIndex))
            encoder.setVertexBytes(&highlightTransform, length: MemoryLayout<Uniforms>.stride, index: 1)
            var borderColor = ColorUniforms(color: SIMD4<Float>(0.2, 0.5, 1.0, 1.0))
            encoder.setFragmentBytes(&borderColor, length: MemoryLayout<ColorUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

            // Inner cell quad (dark background) to create border effect
            var cellTransform = Uniforms(transform: gridLayout.cellTransformForIndex(gridLayout.selectedIndex))
            encoder.setVertexBytes(&cellTransform, length: MemoryLayout<Uniforms>.stride, index: 1)
            var bgColor = ColorUniforms(color: SIMD4<Float>(0.08, 0.08, 0.08, 1.0))
            encoder.setFragmentBytes(&bgColor, length: MemoryLayout<ColorUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        // Draw visible thumbnails
        encoder.setRenderPipelineState(pipelineState)
        for i in visible {
            guard let texture = cache.texture(at: i) else { continue }
            let aspect = cache.aspect(at: i)
            var uniforms = Uniforms(transform: gridLayout.transformForIndex(i, imageAspect: aspect))
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
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
