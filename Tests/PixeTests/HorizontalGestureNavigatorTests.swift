import XCTest

@testable import Pixe

final class HorizontalGestureNavigatorTests: XCTestCase {
    func testLeftSwipeTriggersNextImage() {
        var navigator = HorizontalGestureNavigator()

        XCTAssertNil(navigator.consume(normalizedDeltaX: -0.05, normalizedDeltaY: 0))
        XCTAssertEqual(navigator.consume(normalizedDeltaX: -0.08, normalizedDeltaY: 0.01), 1)
        XCTAssertTrue(navigator.didTrigger)
    }

    func testRightSwipeTriggersPreviousImage() {
        var navigator = HorizontalGestureNavigator()

        XCTAssertEqual(navigator.consume(normalizedDeltaX: 0.13, normalizedDeltaY: 0.01), -1)
        XCTAssertTrue(navigator.didTrigger)
    }

    func testVerticalGestureDoesNotTriggerNavigation() {
        var navigator = HorizontalGestureNavigator()

        XCTAssertNil(navigator.consume(normalizedDeltaX: 0.08, normalizedDeltaY: 0.09))
        XCTAssertNil(navigator.consume(normalizedDeltaX: 0.06, normalizedDeltaY: 0.07))
        XCTAssertFalse(navigator.didTrigger)
    }

    func testResetAllowsSecondGesture() {
        var navigator = HorizontalGestureNavigator()

        XCTAssertEqual(navigator.consume(normalizedDeltaX: -0.13, normalizedDeltaY: 0), 1)
        navigator.reset()
        XCTAssertEqual(navigator.consume(normalizedDeltaX: 0.13, normalizedDeltaY: 0), -1)
    }
}
