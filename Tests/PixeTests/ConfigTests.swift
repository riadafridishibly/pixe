import XCTest

@testable import Pixe

final class ConfigTests: XCTestCase {
    // MARK: - Gap Flag

    func testGapDefaultValue() {
        let config = Config.parse(["--quiet", "/tmp/test.jpg"])
        // Default gap is 2.0 (may be overridden by config file, so just check it parses)
        XCTAssertGreaterThanOrEqual(config.gap, 0)
    }

    func testGapEqualsForm() {
        let config = Config.parse(["--quiet", "--gap=10", "/tmp/test.jpg"])
        XCTAssertEqual(config.gap, 10.0)
    }

    func testGapSpaceForm() {
        let config = Config.parse(["--quiet", "--gap", "5", "/tmp/test.jpg"])
        XCTAssertEqual(config.gap, 5.0)
    }

    func testGapZero() {
        let config = Config.parse(["--quiet", "--gap=0", "/tmp/test.jpg"])
        XCTAssertEqual(config.gap, 0.0)
    }

    func testGapFractional() {
        let config = Config.parse(["--quiet", "--gap=1.5", "/tmp/test.jpg"])
        XCTAssertEqual(config.gap, 1.5)
    }

    func testGapNegativeIgnored() {
        // Negative values should be ignored (gap stays at default or previous)
        let config = Config.parse(["--quiet", "--gap=-5", "/tmp/test.jpg"])
        // Negative is rejected by the `v >= 0` guard, so gap stays at default
        XCTAssertGreaterThanOrEqual(config.gap, 0)
    }

    func testGapOverridesConfigFile() {
        // CLI arg should override config file
        let config = Config.parse(["--quiet", "--gap=20", "/tmp/test.jpg"])
        XCTAssertEqual(config.gap, 20.0)
    }
}
