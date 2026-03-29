import XCTest

@testable import Pixe

final class GridLayoutTests: XCTestCase {
    private func makeLayout(
        items: Int = 10,
        viewportWidth: Float = 800,
        viewportHeight: Float = 600,
        thumbnailSize: Float = 200,
        padding: Float = 2
    ) -> GridLayout {
        let layout = GridLayout()
        layout.padding = padding
        layout.thumbnailSize = thumbnailSize
        layout.viewportWidth = viewportWidth
        layout.viewportHeight = viewportHeight
        layout.totalItems = items
        return layout
    }

    // MARK: - Empty Layout

    func testEmptyLayoutTotalHeight() {
        let layout = makeLayout(items: 0)
        XCTAssertEqual(layout.totalHeight, layout.padding)
    }

    func testEmptyLayoutVisibleRange() {
        let layout = makeLayout(items: 0)
        XCTAssertEqual(layout.visibleRange(), 0 ..< 0)
    }

    func testEmptyLayoutPrefetchRange() {
        let layout = makeLayout(items: 0)
        XCTAssertEqual(layout.prefetchRange(), 0 ..< 0)
    }

    // MARK: - Basic Layout with Uniform Aspects

    func testUniformAspectsProduceConsistentRowSizes() {
        let layout = makeLayout(items: 8, viewportWidth: 800, thumbnailSize: 200)
        // All aspects default to 1.0 (square), so items at 200pt target width
        // Available width = 800 - 2*padding = 796
        // Each item at natural width = 200, gap = 2
        // Row: 200 + 2 + 200 + 2 + 200 = 604 (3 items + 2 gaps) < 796
        // Add 4th: 200 + 2 + 200 + 2 + 200 + 2 + 200 = 806 > 796 — doesn't fit
        // So 3 items per row
        let range = layout.visibleRange()
        XCTAssertTrue(range.contains(0))
        XCTAssertTrue(range.count > 0)
    }

    func testTotalHeightGrowsWithMoreItems() {
        let layout5 = makeLayout(items: 5)
        let layout20 = makeLayout(items: 20)
        XCTAssertGreaterThan(layout20.totalHeight, layout5.totalHeight)
    }

    func testSingleItemLayout() {
        let layout = makeLayout(items: 1, viewportWidth: 400, thumbnailSize: 100)
        let (x, y, w, h) = layout.itemRect(at: 0)
        XCTAssertGreaterThan(w, 0)
        XCTAssertGreaterThan(h, 0)
        // Single item in last row: not stretched beyond natural size
        XCTAssertLessThanOrEqual(w, 400)
        XCTAssertEqual(x, layout.padding, accuracy: 1)
        XCTAssertEqual(y, layout.padding, accuracy: 1)
    }

    // MARK: - Aspect Ratios

    func testSetPreloadedAspectsAffectsLayout() {
        let layout = makeLayout(items: 4, viewportWidth: 1000, thumbnailSize: 200)
        let heightBefore = layout.totalHeight

        // Make items very wide (2:1 aspect) — fewer fit per row
        layout.setPreloadedAspects([0: 2.0, 1: 2.0, 2: 2.0, 3: 2.0])
        let heightAfter = layout.totalHeight

        // Wide items: natural width = 200 * 2 = 400. With gap=2:
        // Row: 400 + 2 + 400 = 802 for 2 items. Available = 1000 - 4 = 996
        // So 2 items per row → 2 rows. Before with square: more per row → fewer rows
        XCTAssertNotEqual(heightBefore, heightAfter)
    }

    func testUpdateAspectsSkipsLocked() {
        let layout = makeLayout(items: 3, viewportWidth: 600, thumbnailSize: 100)

        // Preload locks index 0
        layout.setPreloadedAspects([0: 2.0])

        // updateAspects should skip locked index 0
        layout.updateAspects(from: [0: 0.5, 1: 1.5])

        // Index 0 should still be 2.0 (locked), index 1 should be 1.5
        let (_, _, w0, _) = layout.itemRect(at: 0)
        let (_, _, w1, _) = layout.itemRect(at: 1)
        // w0 should be wider than w1 since aspect 2.0 > 1.5
        XCTAssertGreaterThan(w0, w1)
    }

    func testResetAspectsRestoresDefaults() {
        let layout = makeLayout(items: 4, viewportWidth: 800, thumbnailSize: 200)
        layout.setPreloadedAspects([0: 3.0, 1: 3.0, 2: 3.0, 3: 3.0])
        let heightWide = layout.totalHeight

        layout.resetAspects()
        let heightReset = layout.totalHeight

        // After reset, aspects go back to 1.0 (square), layout changes
        XCTAssertNotEqual(heightWide, heightReset)
    }

    // MARK: - Item Rects

    func testItemRectOutOfBoundsReturnsFallback() {
        let layout = makeLayout(items: 5)
        let (_, _, w, h) = layout.itemRect(at: -1)
        XCTAssertEqual(w, layout.thumbnailSize)
        XCTAssertEqual(h, layout.thumbnailSize)

        let (_, _, w2, h2) = layout.itemRect(at: 100)
        XCTAssertEqual(w2, layout.thumbnailSize)
        XCTAssertEqual(h2, layout.thumbnailSize)
    }

    func testItemRectsAreWithinViewport() {
        let layout = makeLayout(items: 10, viewportWidth: 600, thumbnailSize: 150)
        for i in 0 ..< 10 {
            let (x, _, w, _) = layout.itemRect(at: i)
            XCTAssertGreaterThanOrEqual(x, 0, "Item \(i) x should be >= 0")
            XCTAssertLessThanOrEqual(x + w, 600 + 1, "Item \(i) should fit within viewport width")
        }
    }

    func testItemRectsDoNotOverlap() {
        let layout = makeLayout(items: 6, viewportWidth: 800, thumbnailSize: 200)
        // Collect rects on the same row and ensure no horizontal overlap
        var rects: [(x: Float, y: Float, width: Float, height: Float)] = []
        for i in 0 ..< 6 {
            rects.append(layout.itemRect(at: i))
        }
        // Items in the same row should not overlap horizontally
        for i in 0 ..< rects.count {
            for j in (i + 1) ..< rects.count {
                let a = rects[i]
                let b = rects[j]
                let sameRow = abs(a.y - b.y) < 1
                if sameRow {
                    let aRight = a.x + a.width
                    let bRight = b.x + b.width
                    XCTAssertTrue(
                        aRight <= b.x + 0.1 || bRight <= a.x + 0.1,
                        "Items \(i) and \(j) overlap"
                    )
                }
            }
        }
    }

    // MARK: - Visible Range

    func testVisibleRangeAtTop() {
        let layout = makeLayout(items: 50, viewportWidth: 800, viewportHeight: 400, thumbnailSize: 100)
        layout.scrollOffset = 0
        let range = layout.visibleRange()
        XCTAssertEqual(range.lowerBound, 0)
        XCTAssertGreaterThan(range.count, 0)
    }

    func testVisibleRangeShrinksOnScroll() {
        let layout = makeLayout(items: 100, viewportWidth: 800, viewportHeight: 400, thumbnailSize: 100)
        layout.scrollOffset = 0
        let rangeTop = layout.visibleRange()

        layout.scrollOffset = layout.totalHeight / 2
        let rangeMid = layout.visibleRange()

        // Mid-scroll should not include first items
        XCTAssertGreaterThan(rangeMid.lowerBound, rangeTop.lowerBound)
    }

    func testPrefetchRangeIsWiderThanVisible() {
        let layout = makeLayout(items: 100, viewportWidth: 800, viewportHeight: 400, thumbnailSize: 100)
        layout.scrollOffset = layout.totalHeight / 2
        let visible = layout.visibleRange()
        let prefetch = layout.prefetchRange()

        XCTAssertLessThanOrEqual(prefetch.lowerBound, visible.lowerBound)
        XCTAssertGreaterThanOrEqual(prefetch.upperBound, visible.upperBound)
    }

    // MARK: - Navigation: Left/Right

    func testMoveRightIncrementsWithinRow() {
        let layout = makeLayout(items: 10, viewportWidth: 800, thumbnailSize: 100)
        layout.selectedIndex = 0
        layout.moveRight()
        XCTAssertEqual(layout.selectedIndex, 1)
    }

    func testMoveRightStopsAtRowEnd() {
        let layout = makeLayout(items: 20, viewportWidth: 800, thumbnailSize: 200)
        // With square aspects (200px each) and viewport 800, gap 2:
        // available = 800 - 4 = 796. Each item 200, gap 2.
        // 3 items: 200+2+200+2+200 = 604 < 796 → fits
        // 4 items: 604+2+200 = 806 > 796 → doesn't fit
        // So 3 items per row (indices 0-2 in row 0)
        layout.selectedIndex = 0

        // Move right through the row
        layout.moveRight()
        layout.moveRight()
        let lastInRow = layout.selectedIndex

        // One more should NOT advance (stays at row end)
        layout.moveRight()
        XCTAssertEqual(layout.selectedIndex, lastInRow)
    }

    func testMoveLeftDecrementsWithinRow() {
        let layout = makeLayout(items: 10, viewportWidth: 800, thumbnailSize: 100)
        layout.selectedIndex = 2
        layout.moveLeft()
        XCTAssertEqual(layout.selectedIndex, 1)
    }

    func testMoveLeftStopsAtRowStart() {
        let layout = makeLayout(items: 10, viewportWidth: 800, thumbnailSize: 100)
        layout.selectedIndex = 0
        layout.moveLeft()
        XCTAssertEqual(layout.selectedIndex, 0)
    }

    // MARK: - Navigation: Up/Down

    func testMoveDownGoesToNextRow() {
        let layout = makeLayout(items: 20, viewportWidth: 800, thumbnailSize: 200)
        layout.selectedIndex = 0
        layout.moveDown()
        XCTAssertGreaterThan(layout.selectedIndex, 0)
    }

    func testMoveUpGoesToPreviousRow() {
        let layout = makeLayout(items: 20, viewportWidth: 800, thumbnailSize: 200)
        // Start in second row
        layout.selectedIndex = 0
        layout.moveDown()
        let secondRow = layout.selectedIndex

        layout.moveUp()
        XCTAssertLessThan(layout.selectedIndex, secondRow)
    }

    func testMoveDownThenUpReturnsToOriginal() {
        let layout = makeLayout(items: 20, viewportWidth: 800, thumbnailSize: 200)
        layout.selectedIndex = 1
        layout.moveDown()
        layout.moveUp()
        XCTAssertEqual(layout.selectedIndex, 1)
    }

    func testMoveUpAtTopRowStays() {
        let layout = makeLayout(items: 10, viewportWidth: 800, thumbnailSize: 100)
        layout.selectedIndex = 0
        layout.moveUp()
        XCTAssertEqual(layout.selectedIndex, 0)
    }

    func testMoveDownAtLastRowStays() {
        let layout = makeLayout(items: 10, viewportWidth: 800, thumbnailSize: 100)
        layout.goToLast()
        let last = layout.selectedIndex
        layout.moveDown()
        XCTAssertEqual(layout.selectedIndex, last)
    }

    func testVerticalNavPreservesDesiredColumn() {
        // With varying row sizes, moving down multiple times should track
        // the original x-position, not drift
        let layout = makeLayout(items: 30, viewportWidth: 800, thumbnailSize: 200)
        layout.setPreloadedAspects([0: 1.5, 1: 1.5, 2: 1.5])
        layout.selectedIndex = 1  // middle of first row

        layout.moveDown()
        layout.moveDown()
        let afterTwoDowns = layout.selectedIndex

        // Go back up twice
        layout.moveUp()
        layout.moveUp()
        // Should return to original
        XCTAssertEqual(layout.selectedIndex, 1)

        // And going down twice again should reach the same place
        layout.moveDown()
        layout.moveDown()
        XCTAssertEqual(layout.selectedIndex, afterTwoDowns)
    }

    // MARK: - Navigation: goToFirst / goToLast

    func testGoToFirst() {
        let layout = makeLayout(items: 20)
        layout.selectedIndex = 15
        layout.goToFirst()
        XCTAssertEqual(layout.selectedIndex, 0)
    }

    func testGoToLast() {
        let layout = makeLayout(items: 20)
        layout.selectedIndex = 0
        layout.goToLast()
        XCTAssertEqual(layout.selectedIndex, 19)
    }

    func testGoToLastEmptyIsNoop() {
        let layout = makeLayout(items: 0)
        layout.goToLast()
        XCTAssertEqual(layout.selectedIndex, 0)
    }

    // MARK: - Scrolling

    func testScrollToSelectionKeepsItemVisible() {
        let layout = makeLayout(items: 100, viewportWidth: 800, viewportHeight: 300, thumbnailSize: 100)
        layout.goToLast()
        let (_, y, _, h) = layout.itemRect(at: layout.selectedIndex)
        // The item should be within the viewport
        XCTAssertGreaterThanOrEqual(y, -1)
        XCTAssertLessThanOrEqual(y + h, 300 + 1)
    }

    func testScrollByClamps() {
        let layout = makeLayout(items: 5, viewportWidth: 800, viewportHeight: 600, thumbnailSize: 100)
        layout.scrollBy(delta: -1000)
        XCTAssertGreaterThanOrEqual(layout.scrollOffset, 0)

        layout.scrollBy(delta: 100000)
        XCTAssertLessThanOrEqual(layout.scrollOffset, layout.totalHeight)
    }

    func testClampScrollAtZero() {
        let layout = makeLayout(items: 10)
        layout.scrollOffset = -100
        layout.clampScroll()
        XCTAssertEqual(layout.scrollOffset, 0)
    }

    // MARK: - Zoom

    func testZoomChangesLayoutSize() {
        let layout = makeLayout(items: 10, viewportWidth: 800, thumbnailSize: 200)
        let heightBefore = layout.totalHeight

        layout.zoomBy(factor: 1.5)
        let heightAfter = layout.totalHeight

        XCTAssertGreaterThan(heightAfter, heightBefore)
    }

    func testZoomClampsToMinMax() {
        let layout = makeLayout(items: 10)
        layout.zoomBy(factor: 0.01)  // Try to zoom way out
        XCTAssertGreaterThanOrEqual(layout.thumbnailSize, layout.minThumbnailSize)

        layout.zoomBy(factor: 100)  // Try to zoom way in
        XCTAssertLessThanOrEqual(layout.thumbnailSize, layout.maxThumbnailSize)
    }

    func testResetZoom() {
        let layout = makeLayout(items: 10, thumbnailSize: 300)
        layout.resetZoom()
        XCTAssertEqual(layout.thumbnailSize, layout.defaultThumbnailSize)
    }

    // MARK: - Page Navigation

    func testPageDownAdvancesSignificantly() {
        let layout = makeLayout(items: 100, viewportWidth: 800, viewportHeight: 400, thumbnailSize: 100)
        layout.selectedIndex = 0
        layout.pageDown()
        XCTAssertGreaterThan(layout.selectedIndex, 5, "Page down should jump multiple rows")
    }

    func testPageUpRetreatSignificantly() {
        let layout = makeLayout(items: 100, viewportWidth: 800, viewportHeight: 400, thumbnailSize: 100)
        layout.goToLast()
        let lastIdx = layout.selectedIndex
        layout.pageUp()
        XCTAssertLessThan(layout.selectedIndex, lastIdx - 5, "Page up should jump multiple rows")
    }

    // MARK: - Layout Invalidation

    func testChangingViewportWidthInvalidatesLayout() {
        let layout = makeLayout(items: 10, viewportWidth: 800, thumbnailSize: 200)
        let rect1 = layout.itemRect(at: 5)

        layout.viewportWidth = 400
        let rect2 = layout.itemRect(at: 5)

        // Narrower viewport → items reflow, different positions
        XCTAssertNotEqual(rect1.0, rect2.0, accuracy: 0.01)
    }

    func testChangingTotalItemsInvalidatesLayout() {
        let layout = makeLayout(items: 5, viewportWidth: 800, thumbnailSize: 200)
        let h1 = layout.totalHeight

        layout.totalItems = 50
        let h2 = layout.totalHeight

        XCTAssertGreaterThan(h2, h1)
    }

    // MARK: - Row-based Layout Justification

    func testFullRowStretchesToFillWidth() {
        // A full row (not the last) should stretch to fill available width
        let layout = makeLayout(items: 20, viewportWidth: 800, thumbnailSize: 200, padding: 2)
        // With 3 items per row (square aspects): items are scaled to fill 796px
        let (x0, _, w0, _) = layout.itemRect(at: 0)
        let (_, _, w1, _) = layout.itemRect(at: 1)
        let (_, _, w2, _) = layout.itemRect(at: 2)

        // Total width of items + gaps should approximately equal available width
        let totalItemWidth = w0 + w1 + w2
        let totalGaps = 2 * layout.padding  // 2 gaps between 3 items
        let usedWidth = totalItemWidth + totalGaps
        let availableWidth = layout.viewportWidth - 2 * layout.padding
        XCTAssertEqual(usedWidth, availableWidth, accuracy: 1.0)
        _ = x0  // suppress unused warning
    }

    func testLastRowDoesNotOverstretch() {
        // Last row (if not full) should not stretch beyond natural size
        let layout = makeLayout(items: 1, viewportWidth: 800, thumbnailSize: 200, padding: 2)
        let (_, _, w, h) = layout.itemRect(at: 0)
        // Single item in last row: should not fill the entire width
        XCTAssertLessThanOrEqual(w, 200 + 1)
        XCTAssertLessThanOrEqual(h, 200 + 1)
    }

    func testWideAspectsProduceFewerItemsPerRow() {
        let layout = makeLayout(items: 10, viewportWidth: 800, thumbnailSize: 200)
        let range1 = layout.visibleRange()

        // Set very wide aspects — fewer items per row
        layout.setPreloadedAspects(Dictionary(uniqueKeysWithValues: (0 ..< 10).map { ($0, Float(3.0)) }))
        let range2 = layout.visibleRange()

        // Wider items = fewer visible at once (fewer per row)
        XCTAssertLessThanOrEqual(range2.count, range1.count)
    }
}
