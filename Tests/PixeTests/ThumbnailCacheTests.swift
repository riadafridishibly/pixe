import XCTest

@testable import Pixe

final class ThumbnailCacheTests: XCTestCase {
    // MARK: - Cache Key Formatting (Step 7)

    func testCacheKeyDeterministic() {
        let mtime = 1706000000.123456
        let key1 = ThumbnailCache.cacheKey(for: "/a/b.jpg", mtime: mtime)
        let key2 = ThumbnailCache.cacheKey(for: "/a/b.jpg", mtime: mtime)
        XCTAssertEqual(key1, key2)
    }

    func testCacheKeyVariesWithPath() {
        let mtime = 1000.0
        let key1 = ThumbnailCache.cacheKey(for: "/a.jpg", mtime: mtime)
        let key2 = ThumbnailCache.cacheKey(for: "/b.jpg", mtime: mtime)
        XCTAssertNotEqual(key1, key2)
    }

    func testCacheKeyVariesWithMtime() {
        let key1 = ThumbnailCache.cacheKey(for: "/photo.jpg", mtime: 1000.0)
        let key2 = ThumbnailCache.cacheKey(for: "/photo.jpg", mtime: 1001.0)
        XCTAssertNotEqual(key1, key2)
    }

    func testCacheKeyUsesFixedPrecision() {
        // 0.1 + 0.2 == 0.30000000000000004 in IEEE 754.
        // Without fixed formatting, "\(mtime)" would embed the full
        // representation and produce an unstable key.
        let mtime = 0.1 + 0.2
        let key = ThumbnailCache.cacheKey(for: "/test.jpg", mtime: mtime)
        let expected = ThumbnailCache.sha256("/test.jpg:\(String(format: "%.6f", mtime))")
        XCTAssertEqual(key, expected)
    }

    func testCacheKeyFixedPrecisionIgnoresTrailingNoise() {
        // Two Double values that round to the same 6-decimal string
        // but differ beyond that precision must produce the same key.
        let a = 1706000000.1234561  // 7th decimal: 1
        let b = 1706000000.1234564  // 7th decimal: 4
        // Both should format to "1706000000.123456"
        let keyA = ThumbnailCache.cacheKey(for: "/x.jpg", mtime: a)
        let keyB = ThumbnailCache.cacheKey(for: "/x.jpg", mtime: b)
        XCTAssertEqual(keyA, keyB)
    }

    // MARK: - SHA256

    func testSha256EmptyString() {
        let hash = ThumbnailCache.sha256("")
        XCTAssertEqual(hash, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testSha256KnownValue() {
        // SHA256("hello") is well-known
        let hash = ThumbnailCache.sha256("hello")
        XCTAssertEqual(hash, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    func testSha256Deterministic() {
        let hash1 = ThumbnailCache.sha256("hello world")
        let hash2 = ThumbnailCache.sha256("hello world")
        XCTAssertEqual(hash1, hash2)
    }

    func testSha256DifferentInputsDifferentOutputs() {
        let hash1 = ThumbnailCache.sha256("a")
        let hash2 = ThumbnailCache.sha256("b")
        XCTAssertNotEqual(hash1, hash2)
    }

    // MARK: - Disk Path

    func testDiskPathUsesFirstTwoCharsAsSubdir() {
        let key = "abcdef1234567890"
        let path = ThumbnailCache.diskPath(for: key, thumbDir: "/tmp/thumbs")
        XCTAssertEqual(path, "/tmp/thumbs/ab/abcdef1234567890.jpg")
    }

    func testDiskPathAppendsJpgExtension() {
        let key = "ff00112233"
        let path = ThumbnailCache.diskPath(for: key, thumbDir: "/cache")
        XCTAssertTrue(path.hasSuffix(".jpg"))
    }
}
