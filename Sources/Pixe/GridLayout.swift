import simd
import Foundation

class GridLayout {
    let thumbnailSize: Float = 200.0
    let padding: Float = 10.0

    var viewportWidth: Float = 800.0
    var viewportHeight: Float = 600.0
    var totalItems: Int = 0
    var selectedIndex: Int = 0
    var scrollOffset: Float = 0.0

    var columns: Int {
        max(1, Int((viewportWidth + padding) / (thumbnailSize + padding)))
    }

    var rows: Int {
        guard totalItems > 0 else { return 0 }
        return (totalItems + columns - 1) / columns
    }

    var cellSize: Float {
        thumbnailSize + padding
    }

    var totalHeight: Float {
        Float(rows) * cellSize + padding
    }

    var gridWidth: Float {
        Float(columns) * cellSize + padding
    }

    var gridOffsetX: Float {
        (viewportWidth - gridWidth) / 2.0 + padding
    }

    // MARK: - Position

    func positionForIndex(_ i: Int) -> (x: Float, y: Float) {
        let col = i % columns
        let row = i / columns
        let x = gridOffsetX + Float(col) * cellSize
        let y = padding + Float(row) * cellSize - scrollOffset
        return (x, y)
    }

    // MARK: - Visible Range

    func visibleRange() -> Range<Int> {
        guard totalItems > 0 else { return 0..<0 }
        let firstRow = max(0, Int(scrollOffset / cellSize))
        let lastRow = min(rows - 1, Int((scrollOffset + viewportHeight) / cellSize))
        let start = firstRow * columns
        let end = min(totalItems, (lastRow + 1) * columns)
        return start..<end
    }

    func prefetchRange(buffer: Int = 2) -> Range<Int> {
        guard totalItems > 0 else { return 0..<0 }
        let firstRow = max(0, Int(scrollOffset / cellSize) - buffer)
        let lastRow = min(rows - 1, Int((scrollOffset + viewportHeight) / cellSize) + buffer)
        let start = firstRow * columns
        let end = min(totalItems, (lastRow + 1) * columns)
        return start..<end
    }

    // MARK: - Transforms

    func transformForIndex(_ i: Int, imageAspect: Float) -> simd_float4x4 {
        let (px, py) = positionForIndex(i)

        // Map from point space to NDC
        // Point (0,0) is top-left, NDC (-1,-1) is bottom-left
        let ndcX = (px + thumbnailSize / 2.0) / viewportWidth * 2.0 - 1.0
        let ndcY = 1.0 - (py + thumbnailSize / 2.0) / viewportHeight * 2.0

        // Scale quad to thumbnail size in NDC
        let halfW = thumbnailSize / viewportWidth
        let halfH = thumbnailSize / viewportHeight

        // Fit image aspect within thumbnail cell
        var sx = halfW
        var sy = halfH
        if imageAspect > 1.0 {
            sy = halfH / imageAspect
        } else {
            sx = halfW * imageAspect
        }

        return simd_float4x4(
            SIMD4<Float>(sx, 0,  0, 0),
            SIMD4<Float>(0,  sy, 0, 0),
            SIMD4<Float>(0,  0,  1, 0),
            SIMD4<Float>(ndcX, ndcY, 0, 1)
        )
    }

    func highlightTransformForIndex(_ i: Int) -> simd_float4x4 {
        let (px, py) = positionForIndex(i)
        let border: Float = 4.0

        let ndcX = (px + thumbnailSize / 2.0) / viewportWidth * 2.0 - 1.0
        let ndcY = 1.0 - (py + thumbnailSize / 2.0) / viewportHeight * 2.0

        let sx = (thumbnailSize + border * 2) / viewportWidth
        let sy = (thumbnailSize + border * 2) / viewportHeight

        return simd_float4x4(
            SIMD4<Float>(sx, 0,  0, 0),
            SIMD4<Float>(0,  sy, 0, 0),
            SIMD4<Float>(0,  0,  1, 0),
            SIMD4<Float>(ndcX, ndcY, 0, 1)
        )
    }

    func cellTransformForIndex(_ i: Int) -> simd_float4x4 {
        let (px, py) = positionForIndex(i)

        let ndcX = (px + thumbnailSize / 2.0) / viewportWidth * 2.0 - 1.0
        let ndcY = 1.0 - (py + thumbnailSize / 2.0) / viewportHeight * 2.0

        let sx = thumbnailSize / viewportWidth
        let sy = thumbnailSize / viewportHeight

        return simd_float4x4(
            SIMD4<Float>(sx, 0,  0, 0),
            SIMD4<Float>(0,  sy, 0, 0),
            SIMD4<Float>(0,  0,  1, 0),
            SIMD4<Float>(ndcX, ndcY, 0, 1)
        )
    }

    // MARK: - Navigation

    func moveLeft() {
        let col = selectedIndex % columns
        if col > 0 {
            selectedIndex -= 1
        }
        scrollToSelection()
    }

    func moveRight() {
        let col = selectedIndex % columns
        if col < columns - 1 && selectedIndex + 1 < totalItems {
            selectedIndex += 1
        }
        scrollToSelection()
    }

    func moveUp() {
        if selectedIndex - columns >= 0 {
            selectedIndex -= columns
        }
        scrollToSelection()
    }

    func moveDown() {
        if selectedIndex + columns < totalItems {
            selectedIndex += columns
        } else {
            // Jump to last item if in last partial row
            let lastRow = (totalItems - 1) / columns
            let currentRow = selectedIndex / columns
            if currentRow < lastRow {
                selectedIndex = totalItems - 1
            }
        }
        scrollToSelection()
    }

    func goToFirst() {
        selectedIndex = 0
        scrollToSelection()
    }

    func goToLast() {
        guard totalItems > 0 else { return }
        selectedIndex = totalItems - 1
        scrollToSelection()
    }

    func scrollToSelection() {
        let (_, py) = positionForIndex(selectedIndex)
        let actualY = py + scrollOffset // position without scroll applied

        // Scroll up if selection is above visible area
        if actualY - scrollOffset < 0 {
            scrollOffset = actualY
        }
        // Scroll down if selection is below visible area
        if actualY + cellSize - scrollOffset > viewportHeight {
            scrollOffset = actualY + cellSize - viewportHeight
        }
        clampScroll()
    }

    func scrollBy(delta: Float) {
        scrollOffset += delta
        clampScroll()
    }

    func clampScroll() {
        let maxScroll = max(0, totalHeight - viewportHeight)
        scrollOffset = max(0, min(scrollOffset, maxScroll))
    }
}
