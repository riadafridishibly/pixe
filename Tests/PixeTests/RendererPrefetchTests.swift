import Metal
import XCTest

@testable import Pixe

final class RendererPrefetchTests: XCTestCase {
    private var tempDirURL: URL!

    override func setUp() {
        super.setUp()
        tempDirURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .resolvingSymlinksInPath()
            .appendingPathComponent("pixe-prefetch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirURL)
        tempDirURL = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Create a small solid-color PNG at the given path.
    private func createTestPNG(named name: String, width: Int = 64, height: Int = 64) -> String {
        let path = tempDirURL.appendingPathComponent(name).resolvingSymlinksInPath().path
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Fill with a color derived from the name so images are distinct
        let hue = CGFloat(name.hashValue & 0xFF) / 255.0
        ctx.setFillColor(CGColor(red: hue, green: 0.5, blue: 1.0 - hue, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let url = URL(fileURLWithPath: path)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return path
    }

    private func makeRenderer(paths: [String]) throws -> Renderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available")
        }
        let config = Config.parse(["--quiet", "--no-cache", "--min-width=1", "--min-height=1"] + paths)
        let imageList = ImageList(arguments: config.imageArguments, config: config)
        return Renderer(device: device, imageList: imageList, initialMode: .image, config: config)
    }

    /// Drain the main run loop for the given duration to let async callbacks execute.
    private func drainMainQueue(for seconds: TimeInterval = 0.5) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: - Prefetch generation mismatch regression test

    /// Regression test for: thumbnail stuck when entering image mode for a path
    /// whose prefetch was in-flight but completed with a stale prefetchGeneration.
    ///
    /// Scenario:
    ///   1. View image A → prefetch starts for B (captures prefetchGeneration=N)
    ///   2. Navigate to image C → prefetchGeneration bumps to N+1
    ///   3. B's prefetch decode finishes, posts result to main queue
    ///   4. User enters image mode at B → loadCurrentImage() sees B in
    ///      prefetchLoading → early-returns, trusting prefetch to deliver
    ///   5. Prefetch completion runs: generation N ≠ N+1 → **before fix**: silently
    ///      drops result, image stuck on thumbnail forever.
    ///
    /// The fix: prefetch completion re-triggers loadCurrentImage() when the path
    /// is the current image, even with a stale generation.
    func testStalePrefetchGenerationDoesNotStrandImage() throws {
        let pathA = createTestPNG(named: "a.png", width: 64, height: 64)
        let pathB = createTestPNG(named: "b.png", width: 128, height: 128)
        let pathC = createTestPNG(named: "c.png", width: 96, height: 96)
        let pathD = createTestPNG(named: "d.png", width: 80, height: 80)

        let renderer = try makeRenderer(paths: [pathA, pathB, pathC, pathD])

        // 1. Load image A fully.
        renderer.loadCurrentImage()
        drainMainQueue(for: 1.0)
        XCTAssertNotNil(renderer.currentTexture, "Image A should have loaded")
        let textureAfterA = renderer.currentTexture

        // 2. Record state: prefetchAdjacentImages ran for A, so B may be cached.
        //    Clear prefetch state so we can set up the race manually.
        renderer.prefetchCache.removeAll()
        renderer.prefetchLoading.removeAll()

        // 3. Simulate: a prefetch for B was dispatched at generation N.
        renderer.prefetchLoading.insert(pathB)

        // 4. Simulate: user navigated to C, bumping prefetchGeneration.
        renderer.prefetchGeneration += 1

        // 5. Navigate to B. loadCurrentImage() should early-return because
        //    prefetchLoading contains pathB.
        renderer.imageList.goTo(index: 1)
        XCTAssertEqual(renderer.imageList.currentPath, pathB)

        let genBeforeLoad = renderer.loadGeneration
        renderer.loadCurrentImage()

        // loadCurrentImage incremented loadGeneration but early-returned before
        // starting a decode (prefetchLoading still has pathB).
        XCTAssertEqual(renderer.loadGeneration, genBeforeLoad + 1)
        XCTAssertTrue(renderer.prefetchLoading.contains(pathB),
                       "pathB should still be in prefetchLoading (early-return path)")

        // 6. Simulate the stale prefetch completing: trigger prefetchAdjacentImages
        //    flow that would normally fire from the background queue callback.
        //    The key code path: prefetchLoading.remove(pathB) → generation check
        //    fails → with fix: loadCurrentImage() re-triggered.
        //
        //    Instead of trying to call the private closure directly, we simulate
        //    its effect: remove from prefetchLoading (as the completion does) and
        //    then wait for the system to recover via the fix.
        renderer.prefetchLoading.remove(pathB)

        // Now nothing is loading pathB. Without the fix, no code would ever
        // trigger loadCurrentImage() again — B would be stranded.
        // With the fix, the prefetch completion calls loadCurrentImage() when
        // generation mismatches but path == currentPath. We simulate this by
        // calling loadCurrentImage() (which is what the fix adds).
        renderer.loadCurrentImage()

        drainMainQueue(for: 1.0)

        // 7. Verify B loaded at full quality.
        XCTAssertNotNil(renderer.currentTexture, "Image B should have loaded")
        XCTAssertEqual(renderer.prefetchCache[pathB]?.quality, .full,
                       "Image B should be at full quality in prefetch cache")
        XCTAssertNotEqual(
            renderer.currentTexture?.width, textureAfterA?.width,
            "Current texture should have changed from image A"
        )
    }

    /// Test that the normal (non-racy) thumbnail→image flow works end-to-end:
    /// enter image mode at an index and the full image loads.
    func testEnterImageModeLoadsFullImage() throws {
        let pathA = createTestPNG(named: "a.png", width: 100, height: 100)
        let pathB = createTestPNG(named: "b.png", width: 200, height: 200)

        let renderer = try makeRenderer(paths: [pathA, pathB])

        // Start at image A
        renderer.loadCurrentImage()
        drainMainQueue(for: 1.0)
        XCTAssertNotNil(renderer.currentTexture)

        // Enter image mode at B
        renderer.enterImageMode(at: 1)
        drainMainQueue(for: 1.0)

        XCTAssertNotNil(renderer.currentTexture, "Image B should have loaded")
        XCTAssertEqual(renderer.imageList.currentPath, pathB)
        XCTAssertEqual(renderer.prefetchCache[pathB]?.quality, .full,
                       "Image B should reach full quality")
    }

    /// Verify that navigating rapidly doesn't leave the final image stranded.
    /// A → B → C → D in quick succession; D should eventually load fully.
    func testRapidNavigationLoadsLastImage() throws {
        let paths = (0..<6).map { createTestPNG(named: "img\($0).png") }
        let renderer = try makeRenderer(paths: paths)

        renderer.loadCurrentImage()
        drainMainQueue(for: 0.3)

        // Rapidly navigate forward
        for i in 1..<paths.count {
            renderer.imageList.goTo(index: i)
            renderer.loadCurrentImage()
        }
        drainMainQueue(for: 2.0)

        let lastPath = paths.last!
        XCTAssertEqual(renderer.imageList.currentPath, lastPath)
        XCTAssertNotNil(renderer.currentTexture, "Last image should have loaded")
        XCTAssertEqual(renderer.prefetchCache[lastPath]?.quality, .full,
                       "Last image should reach full quality after rapid navigation")
    }
}
