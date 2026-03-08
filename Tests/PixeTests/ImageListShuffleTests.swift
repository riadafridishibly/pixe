import XCTest

@testable import Pixe

final class ImageListShuffleTests: XCTestCase {
    private var tempDirURL: URL!

    override func setUp() {
        super.setUp()
        tempDirURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .resolvingSymlinksInPath()
            .appendingPathComponent("pixe-imagelist-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirURL)
        tempDirURL = nil
        super.tearDown()
    }

    func testUnshuffleRetainsFilesDiscoveredAfterShuffle() {
        let a = writeTestImage(named: "a.png")
        let b = writeTestImage(named: "b.png")
        let c = writeTestImage(named: "c.png")

        let config = Config.parse(["--quiet", "--no-cache", a, tempDirURL.path])
        let imageList = ImageList(arguments: config.imageArguments, config: config)

        imageList.shuffle()
        XCTAssertTrue(imageList.isShuffled)

        waitForEnumeration(of: imageList)
        XCTAssertEqual(normalizedPathSet(imageList.allPaths), normalizedPathSet([a, b, c]))

        imageList.unshuffle()
        XCTAssertFalse(imageList.isShuffled)
        XCTAssertEqual(normalizedPathSet(imageList.allPaths), normalizedPathSet([a, b, c]))
    }

    func testShuffleBeforeEnumerationPersistsThroughDirectoryScan() {
        let a = writeTestImage(named: "x.png")
        let b = writeTestImage(named: "y.png")

        let config = Config.parse(["--quiet", "--no-cache", tempDirURL.path])
        let imageList = ImageList(arguments: config.imageArguments, config: config)

        XCTAssertEqual(imageList.count, 0)
        imageList.shuffle()
        XCTAssertTrue(imageList.isShuffled)

        waitForEnumeration(of: imageList)
        XCTAssertTrue(imageList.isShuffled)
        XCTAssertEqual(normalizedPathSet(imageList.allPaths), normalizedPathSet([a, b]))

        imageList.unshuffle()
        XCTAssertFalse(imageList.isShuffled)
        XCTAssertEqual(normalizedPathSet(imageList.allPaths), normalizedPathSet([a, b]))
    }

    private func writeTestImage(named name: String) -> String {
        let path = tempDirURL.appendingPathComponent(name).resolvingSymlinksInPath().path
        let png1x1 = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO2X3uoAAAAASUVORK5CYII=")!
        try! png1x1.write(to: URL(fileURLWithPath: path))
        return path
    }

    private func waitForEnumeration(of imageList: ImageList, timeout: TimeInterval = 5.0) {
        let complete = expectation(description: "enumeration complete")
        imageList.onEnumerationComplete = { _ in complete.fulfill() }
        imageList.startEnumerationIfNeeded()
        wait(for: [complete], timeout: timeout)
    }

    private func normalizedPathSet(_ paths: [String]) -> Set<String> {
        Set(paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
    }
}
