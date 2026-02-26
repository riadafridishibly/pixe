import Metal
import MetalKit

class GIFAnimator {
    let frameTextures: [MTLTexture]
    let frameDelays: [TimeInterval]
    let frameCount: Int
    let aspect: Float
    private(set) var currentFrameIndex: Int = 0
    private var timer: DispatchSourceTimer?
    private weak var view: MTKView?

    var currentTexture: MTLTexture { frameTextures[currentFrameIndex] }

    init?(textures: [MTLTexture], delays: [TimeInterval]) {
        guard textures.count > 1, textures.count == delays.count else { return nil }
        self.frameTextures = textures
        self.frameDelays = delays.map { $0 <= 0.01 ? 0.1 : $0 }
        self.frameCount = textures.count
        let first = textures[0]
        self.aspect = Float(first.width) / Float(first.height)
    }

    func start(view: MTKView) {
        stop()
        self.view = view
        let timer = DispatchSource.makeTimerSource(queue: .main)
        self.timer = timer
        let delay = frameDelays[currentFrameIndex]
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.advanceFrame()
        }
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        view = nil
    }

    deinit {
        stop()
    }

    private func advanceFrame() {
        currentFrameIndex = (currentFrameIndex + 1) % frameCount
        view?.needsDisplay = true
        let delay = frameDelays[currentFrameIndex]
        timer?.schedule(deadline: .now() + delay)
    }
}
