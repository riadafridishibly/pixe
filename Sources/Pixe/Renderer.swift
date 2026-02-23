import MetalKit
import simd

struct Uniforms {
    var transform: simd_float4x4
}

struct Vertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var pipelineState: MTLRenderPipelineState!
    var samplerState: MTLSamplerState!
    var vertexBuffer: MTLBuffer!

    var currentTexture: MTLTexture?
    let imageList: ImageList
    weak var window: ImageWindow?

    // Zoom/pan state
    var scale: Float = 1.0
    var translation: SIMD2<Float> = .zero
    var imageAspect: Float = 1.0
    var viewportSize: SIMD2<Float> = SIMD2(800, 600)

    init(device: MTLDevice, imageList: ImageList) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.imageList = imageList
        super.init()
        setupPipeline()
        setupVertexBuffer()
        setupSampler()
    }

    private func setupPipeline() {
        let library = try! device.makeLibrary(source: ShaderSource.metalSource, options: nil)
        let vertexFunction = library.makeFunction(name: "vertexShader")!
        let fragmentFunction = library.makeFunction(name: "fragmentShader")!

        let vertexDescriptor = MTLVertexDescriptor()
        // position: float2 at offset 0
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        // texCoord: float2 at offset 8
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        // Enable alpha blending for images with transparency
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    private func setupVertexBuffer() {
        // Unit quad: two triangles covering (-1,-1) to (1,1)
        // Texture coords: (0,0) top-left to (1,1) bottom-right
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

        // Fit image aspect ratio within viewport
        var sx: Float = 1.0
        var sy: Float = 1.0
        if imageAspect > viewAspect {
            sy = viewAspect / imageAspect
        } else {
            sx = imageAspect / viewAspect
        }

        // Apply user zoom
        sx *= scale
        sy *= scale

        let tx = translation.x
        let ty = translation.y

        // Column-major 4x4 matrix
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
                // Trigger redraw
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
        guard let path = imageList.currentPath else { return }
        let filename = (path as NSString).lastPathComponent
        window?.updateTitle(filename: filename, index: imageList.currentIndex, total: imageList.count)
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
    }

    func draw(in view: MTKView) {
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
}
