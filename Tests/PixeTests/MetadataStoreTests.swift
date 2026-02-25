import XCTest

@testable import Pixe

final class MetadataStoreTests: XCTestCase {
    private var tempDir: String!
    private var store: MetadataStore!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "pixe-test-\(UUID().uuidString)"
        store = MetadataStore(directory: tempDir)
        XCTAssertNotNil(store, "MetadataStore should initialize with a temp directory")
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Thumbnail Metadata

    func testThumbnailUpsertAndFetch() {
        store.upsertThumbnail(
            key: "k1", sourcePath: "/photo.jpg", sourceMtime: 1000.0,
            width: 200, height: 150, aspect: 1.333
        )

        let meta = store.thumbnail(forKey: "k1")
        XCTAssertNotNil(meta)
        XCTAssertEqual(meta?.width, 200)
        XCTAssertEqual(meta?.height, 150)
        XCTAssertEqual(meta?.aspect ?? 0, 1.333, accuracy: 0.001)
    }

    func testThumbnailMissing() {
        XCTAssertNil(store.thumbnail(forKey: "nonexistent"))
    }

    func testThumbnailRemoval() {
        store.upsertThumbnail(
            key: "rm", sourcePath: "/x.jpg", sourceMtime: 1.0,
            width: 100, height: 100, aspect: 1.0
        )
        XCTAssertNotNil(store.thumbnail(forKey: "rm"))

        store.removeThumbnail(forKey: "rm")
        XCTAssertNil(store.thumbnail(forKey: "rm"))
    }

    func testThumbnailUpsertOverwrites() {
        store.upsertThumbnail(
            key: "ow", sourcePath: "/a.jpg", sourceMtime: 1.0,
            width: 100, height: 100, aspect: 1.0
        )
        store.upsertThumbnail(
            key: "ow", sourcePath: "/a.jpg", sourceMtime: 2.0,
            width: 300, height: 200, aspect: 1.5
        )

        let meta = store.thumbnail(forKey: "ow")
        XCTAssertEqual(meta?.width, 300)
        XCTAssertEqual(meta?.height, 200)
    }

    func testAllThumbnailKeys() {
        store.upsertThumbnail(
            key: "k1", sourcePath: "/a.jpg", sourceMtime: 1.0,
            width: 100, height: 100, aspect: 1.0
        )
        store.upsertThumbnail(
            key: "k2", sourcePath: "/b.jpg", sourceMtime: 2.0,
            width: 200, height: 200, aspect: 1.0
        )

        let keys = store.allThumbnailKeys()
        XCTAssertEqual(keys, Set(["k1", "k2"]))
    }

    // MARK: - Directory Entries (Step 4: replaceDirectoryEntries)

    func testReplaceDirectoryEntriesPersists() {
        let paths = ["/photos/a.jpg", "/photos/b.jpg", "/photos/c.jpg"]
        store.replaceDirectoryEntries(dirPath: "/photos", paths: paths)

        let cached = store.cachedDirectoryEntries(dirPath: "/photos", filter: .exclude([]))
        XCTAssertEqual(Set(cached), Set(paths))
    }

    func testReplaceDirectoryEntriesOverwritesOld() {
        store.replaceDirectoryEntries(dirPath: "/photos", paths: ["/photos/old.jpg"])

        let newPaths = ["/photos/new1.jpg", "/photos/new2.jpg"]
        store.replaceDirectoryEntries(dirPath: "/photos", paths: newPaths)

        let cached = store.cachedDirectoryEntries(dirPath: "/photos", filter: .exclude([]))
        XCTAssertEqual(Set(cached), Set(newPaths))
        XCTAssertFalse(cached.contains("/photos/old.jpg"))
    }

    func testReplaceDirectoryEntriesEmptyList() {
        store.replaceDirectoryEntries(dirPath: "/photos", paths: ["/photos/a.jpg"])
        store.replaceDirectoryEntries(dirPath: "/photos", paths: [])

        let cached = store.cachedDirectoryEntries(dirPath: "/photos", filter: .exclude([]))
        XCTAssertTrue(cached.isEmpty)
    }

    func testDirectoryEntriesPrefixQuery() {
        // Entries under /photos should be found when querying /photos/vacation
        let paths = ["/photos/vacation/a.jpg", "/photos/vacation/b.jpg", "/photos/work/c.jpg"]
        store.replaceDirectoryEntries(dirPath: "/photos", paths: paths)

        let vacationOnly = store.cachedDirectoryEntries(dirPath: "/photos/vacation", filter: .exclude([]))
        XCTAssertEqual(Set(vacationOnly), Set(["/photos/vacation/a.jpg", "/photos/vacation/b.jpg"]))
    }

    // MARK: - EXIF Metadata

    func testCachedExifWithDate() {
        let captureDate = Date(timeIntervalSince1970: 1705000000.0)
        store.upsertExif(path: "/photo.jpg", mtime: 1000.0, fileSize: 5_000_000, captureDate: captureDate)

        let result = store.cachedExif(path: "/photo.jpg", mtime: 1000.0, fileSize: 5_000_000)
        XCTAssertNotNil(result)
        if case .date(let date) = result {
            XCTAssertEqual(date.timeIntervalSince1970, captureDate.timeIntervalSince1970, accuracy: 0.001)
        } else {
            XCTFail("Expected .date, got \(String(describing: result))")
        }
    }

    func testCachedExifWithoutDate() {
        store.upsertExif(path: "/photo.jpg", mtime: 1000.0, fileSize: 5000, captureDate: nil)

        let result = store.cachedExif(path: "/photo.jpg", mtime: 1000.0, fileSize: 5000)
        XCTAssertNotNil(result)
        if case .missing = result {
            // expected
        } else {
            XCTFail("Expected .missing, got \(String(describing: result))")
        }
    }

    func testCachedExifInvalidatedByMtimeChange() {
        store.upsertExif(path: "/photo.jpg", mtime: 1000.0, fileSize: 5000, captureDate: Date())

        // Different mtime → stale → nil
        let result = store.cachedExif(path: "/photo.jpg", mtime: 2000.0, fileSize: 5000)
        XCTAssertNil(result)
    }

    func testCachedExifInvalidatedByFileSizeChange() {
        store.upsertExif(path: "/photo.jpg", mtime: 1000.0, fileSize: 5000, captureDate: Date())

        // Different fileSize → stale → nil
        let result = store.cachedExif(path: "/photo.jpg", mtime: 1000.0, fileSize: 9999)
        XCTAssertNil(result)
    }

    func testCachedExifMissForUnknownPath() {
        let result = store.cachedExif(path: "/nonexistent.jpg", mtime: 0, fileSize: 0)
        XCTAssertNil(result)
    }

    // MARK: - Dimensions

    func testCachedDimensionsRoundTrip() {
        store.upsertDimensions(path: "/photo.jpg", width: 4000, height: 3000)

        let dims = store.cachedDimensions(path: "/photo.jpg")
        XCTAssertNotNil(dims)
        XCTAssertEqual(dims?.width, 4000)
        XCTAssertEqual(dims?.height, 3000)
    }

    func testCachedDimensionsMissForUnknownPath() {
        XCTAssertNil(store.cachedDimensions(path: "/nonexistent.jpg"))
    }

    func testCachedDimensionsOverwrite() {
        store.upsertDimensions(path: "/photo.jpg", width: 100, height: 100)
        store.upsertDimensions(path: "/photo.jpg", width: 4000, height: 3000)

        let dims = store.cachedDimensions(path: "/photo.jpg")
        XCTAssertEqual(dims?.width, 4000)
        XCTAssertEqual(dims?.height, 3000)
    }
}
