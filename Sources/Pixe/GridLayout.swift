import simd
import Foundation

class GridLayout {
    let defaultThumbnailSize: Float = 200.0
    let minThumbnailSize: Float = 96.0
    let maxThumbnailSize: Float = 420.0
    var thumbnailSize: Float = 200.0
    let padding: Float = 10.0

    var viewportWidth: Float = 800.0
    var viewportHeight: Float = 600.0
    var totalItems: Int = 0
    var selectedIndex: Int = 0
    var scrollOffset: Float = 0.0

    let selectionBorder: Float = 6.0

    var columns: Int {
        max(1, Int((viewportWidth - selectionBorder * 2 + padding) / (thumbnailSize + padding)))
    }

    var rows: Int {
        guard totalItems > 0 else { return 0 }
        return (totalItems + columns - 1) / columns
    }

    var cellSize: Float {
        thumbnailSize + padding
    }

    var totalHeight: Float {
        Float(rows) * cellSize + padding + selectionBorder
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

    func outerHighlightTransformForIndex(_ i: Int) -> simd_float4x4 {
        let (px, py) = positionForIndex(i)
        let border: Float = 6.0

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

    func zoomBy(factor: Float) {
        setThumbnailSize(thumbnailSize * factor)
    }

    func resetZoom() {
        setThumbnailSize(defaultThumbnailSize)
    }

    private func setThumbnailSize(_ newSize: Float) {
        thumbnailSize = max(minThumbnailSize, min(maxThumbnailSize, newSize))
        scrollToSelection()
    }

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

    func pageUp() {
        let visibleRows = max(1, Int(viewportHeight / cellSize))
        let newIndex = selectedIndex - visibleRows * columns
        if newIndex >= 0 {
            selectedIndex = newIndex
        } else {
            selectedIndex = selectedIndex % columns
        }
        scrollToSelection()
    }

    func pageDown() {
        guard totalItems > 0 else { return }
        let visibleRows = max(1, Int(viewportHeight / cellSize))
        let newIndex = selectedIndex + visibleRows * columns
        if newIndex < totalItems {
            selectedIndex = newIndex
        } else {
            selectedIndex = totalItems - 1
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
        let row = selectedIndex / columns
        let itemY = padding + Float(row) * cellSize

        // Ensure border above selection is visible
        if itemY - selectionBorder < scrollOffset {
            scrollOffset = itemY - selectionBorder
        }
        // Ensure border below selection is visible
        if itemY + thumbnailSize + selectionBorder > scrollOffset + viewportHeight {
            scrollOffset = itemY + thumbnailSize + selectionBorder - viewportHeight
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
