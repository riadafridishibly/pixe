import XCTest

@testable import Pixe

final class ImageLoaderTests: XCTestCase {
    // MARK: - RAW Detection

    func testIsRawFileRecognizesAllFormats() {
        let rawExtensions = [
            "arw", "cr2", "cr3", "nef", "raf",
            "orf", "rw2", "dng", "pef", "srw", "x3f",
        ]
        for ext in rawExtensions {
            XCTAssertTrue(
                ImageLoader.isRawFile("/photo.\(ext)"),
                "\(ext) should be recognized as RAW"
            )
        }
    }

    func testIsRawFileCaseInsensitive() {
        XCTAssertTrue(ImageLoader.isRawFile("/photo.ARW"))
        XCTAssertTrue(ImageLoader.isRawFile("/photo.Cr2"))
        XCTAssertTrue(ImageLoader.isRawFile("/photo.DNG"))
        XCTAssertTrue(ImageLoader.isRawFile("/photo.NeF"))
    }

    func testIsRawFileRejectsNonRaw() {
        XCTAssertFalse(ImageLoader.isRawFile("/photo.jpg"))
        XCTAssertFalse(ImageLoader.isRawFile("/photo.png"))
        XCTAssertFalse(ImageLoader.isRawFile("/photo.heic"))
        XCTAssertFalse(ImageLoader.isRawFile("/photo.webp"))
        XCTAssertFalse(ImageLoader.isRawFile("/photo.tiff"))
    }

    func testIsRawFileRejectsNoExtension() {
        XCTAssertFalse(ImageLoader.isRawFile("/photo"))
        XCTAssertFalse(ImageLoader.isRawFile("/some/path/file"))
    }
}
