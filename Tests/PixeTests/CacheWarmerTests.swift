import XCTest

@testable import Pixe

final class CacheWarmerTests: XCTestCase {
    // MARK: - Deduplication Pattern (Step 1)

    // Tests the exact pattern used in CacheWarmer.run():
    //   var seen = Set<String>()
    //   allFiles = allFiles.filter { seen.insert($0).inserted }

    func testDeduplicateRemovesDuplicatesPreservingOrder() {
        var files = ["/a.jpg", "/b.jpg", "/a.jpg", "/c.jpg", "/b.jpg", "/d.jpg"]
        var seen = Set<String>()
        files = files.filter { seen.insert($0).inserted }

        XCTAssertEqual(files, ["/a.jpg", "/b.jpg", "/c.jpg", "/d.jpg"])
    }

    func testDeduplicateNoDuplicatesIsNoop() {
        var files = ["/a.jpg", "/b.jpg", "/c.jpg"]
        var seen = Set<String>()
        files = files.filter { seen.insert($0).inserted }

        XCTAssertEqual(files, ["/a.jpg", "/b.jpg", "/c.jpg"])
    }

    func testDeduplicateEmpty() {
        var files: [String] = []
        var seen = Set<String>()
        files = files.filter { seen.insert($0).inserted }

        XCTAssertTrue(files.isEmpty)
    }

    func testDeduplicateAllSame() {
        var files = ["/a.jpg", "/a.jpg", "/a.jpg"]
        var seen = Set<String>()
        files = files.filter { seen.insert($0).inserted }

        XCTAssertEqual(files, ["/a.jpg"])
    }

    func testDeduplicateOverlappingDirectories() {
        // Simulates the case where photos/ and photos/vacation/ both discover
        // photos/vacation/img1.jpg
        var files = [
            "/photos/beach/img1.jpg",
            "/photos/vacation/img1.jpg",
            "/photos/vacation/img2.jpg",
            "/photos/vacation/img1.jpg",  // duplicate from overlapping walk
            "/photos/vacation/img2.jpg",  // duplicate from overlapping walk
        ]
        var seen = Set<String>()
        files = files.filter { seen.insert($0).inserted }

        XCTAssertEqual(files, [
            "/photos/beach/img1.jpg",
            "/photos/vacation/img1.jpg",
            "/photos/vacation/img2.jpg",
        ])
    }
}
