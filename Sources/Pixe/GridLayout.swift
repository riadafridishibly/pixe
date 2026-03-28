import Foundation
import simd

class GridLayout {
    let defaultThumbnailSize: Float = 200.0
    let minThumbnailSize: Float = 96.0
    let maxThumbnailSize: Float = 420.0
    var thumbnailSize: Float = 200.0 {
        didSet { if oldValue != thumbnailSize { invalidateLayout() } }
    }
    var padding: Float = 2.0 {
        didSet { if oldValue != padding { invalidateLayout() } }
    }

    var viewportWidth: Float = 800.0 {
        didSet { if oldValue != viewportWidth { invalidateLayout() } }
    }
    var viewportHeight: Float = 600.0
    var totalItems: Int = 0 {
        didSet { if oldValue != totalItems { invalidateLayout() } }
    }
    var selectedIndex: Int = 0
    var scrollOffset: Float = 0.0

    let selectionBorder: Float = 6.0

    // MARK: - Justified Layout Data

    private struct ItemRect {
        var x: Float
        var y: Float
        var width: Float
        var height: Float
    }

    private struct RowInfo {
        var startIndex: Int
        var count: Int
        var y: Float
        var height: Float
    }

    private var itemRects: [ItemRect] = []
    private var rowInfos: [RowInfo] = []
    private var aspects: [Float] = []
    private var layoutDirty = true

    // MARK: - Aspect Ratios

    func updateAspects(from cacheAspects: [Int: Float]) {
        var changed = false
        for (index, aspect) in cacheAspects {
            ensureAspectsCapacity(index + 1)
            if aspects[index] != aspect {
                aspects[index] = aspect
                changed = true
            }
        }
        if changed { invalidateLayout() }
    }

    private func ensureAspectsCapacity(_ needed: Int) {
        if aspects.count < needed {
            aspects.append(contentsOf: repeatElement(Float(1.0), count: needed - aspects.count))
        }
    }

    func invalidateLayout() {
        layoutDirty = true
    }

    // MARK: - Layout Computation

    private func ensureLayout() {
        guard layoutDirty else { return }
        recomputeLayout()
        layoutDirty = false
    }

    private func recomputeLayout() {
        itemRects = Array(repeating: ItemRect(x: 0, y: 0, width: 0, height: 0), count: totalItems)
        rowInfos.removeAll()

        guard totalItems > 0 else { return }

        ensureAspectsCapacity(totalItems)

        let margin = padding
        let gap = padding
        let availableWidth = viewportWidth - 2 * margin
        let targetHeight = thumbnailSize

        guard availableWidth > 0 && targetHeight > 0 else { return }

        var rowStart = 0
        var currentY = margin

        while rowStart < totalItems {
            var rowNaturalWidth: Float = 0
            var itemsInRow = 0
            var idx = rowStart

            // Pack items into this row until it overflows
            while idx < totalItems {
                let aspect = max(aspects[idx], 0.1)
                let itemNatWidth = targetHeight * aspect
                let newNatWidth = rowNaturalWidth + itemNatWidth
                let gapWidth = Float(itemsInRow) * gap
                let newTotalWidth = newNatWidth + gapWidth

                if newTotalWidth > availableWidth && itemsInRow > 0 {
                    break
                }

                rowNaturalWidth = newNatWidth
                itemsInRow += 1
                idx += 1
            }

            let rowEnd = rowStart + itemsInRow

            // Scale row to fill available width (except last row)
            let totalGaps = Float(max(0, itemsInRow - 1)) * gap
            let imageSpace = availableWidth - totalGaps
            let scale: Float
            if rowEnd < totalItems {
                scale = rowNaturalWidth > 0 ? imageSpace / rowNaturalWidth : 1.0
            } else {
                scale = rowNaturalWidth > 0 ? min(1.0, imageSpace / rowNaturalWidth) : 1.0
            }
            let rowHeight = targetHeight * scale

            // Position each item in the row
            var x = margin
            for i in rowStart ..< rowEnd {
                let aspect = max(aspects[i], 0.1)
                let itemWidth = rowHeight * aspect
                itemRects[i] = ItemRect(x: x, y: currentY, width: itemWidth, height: rowHeight)
                x += itemWidth + gap
            }

            rowInfos.append(RowInfo(startIndex: rowStart, count: itemsInRow, y: currentY, height: rowHeight))
            currentY += rowHeight + gap
            rowStart = rowEnd
        }
    }

    // MARK: - Computed Properties

    var totalHeight: Float {
        ensureLayout()
        guard let lastRow = rowInfos.last else { return padding }
        return lastRow.y + lastRow.height + padding + selectionBorder
    }

    // MARK: - Item Access

    /// Returns item rect in scroll-adjusted coordinates (for rendering).
    func itemRect(at index: Int) -> (x: Float, y: Float, width: Float, height: Float) {
        ensureLayout()
        guard index >= 0, index < itemRects.count else {
            return (0, 0, thumbnailSize, thumbnailSize)
        }
        let r = itemRects[index]
        return (r.x, r.y - scrollOffset, r.width, r.height)
    }

    // MARK: - Visible Range

    func visibleRange() -> Range<Int> {
        ensureLayout()
        guard !rowInfos.isEmpty else { return 0 ..< 0 }

        let top = scrollOffset
        let bottom = scrollOffset + viewportHeight

        var firstRow = 0
        for (ri, row) in rowInfos.enumerated() {
            if row.y + row.height >= top {
                firstRow = ri
                break
            }
        }

        var lastRow = rowInfos.count - 1
        for ri in firstRow ..< rowInfos.count {
            if rowInfos[ri].y > bottom {
                lastRow = max(firstRow, ri - 1)
                break
            }
        }

        let start = rowInfos[firstRow].startIndex
        let lastRowInfo = rowInfos[lastRow]
        let end = min(totalItems, lastRowInfo.startIndex + lastRowInfo.count)
        return start ..< end
    }

    func prefetchRange(buffer: Int = 2) -> Range<Int> {
        ensureLayout()
        guard !rowInfos.isEmpty else { return 0 ..< 0 }

        let top = scrollOffset
        let bottom = scrollOffset + viewportHeight

        var firstVisibleRow = 0
        for (ri, row) in rowInfos.enumerated() {
            if row.y + row.height >= top {
                firstVisibleRow = ri
                break
            }
        }
        let firstRow = max(0, firstVisibleRow - buffer)

        var lastVisibleRow = rowInfos.count - 1
        for ri in firstVisibleRow ..< rowInfos.count {
            if rowInfos[ri].y > bottom {
                lastVisibleRow = max(firstVisibleRow, ri - 1)
                break
            }
        }
        let lastRow = min(rowInfos.count - 1, lastVisibleRow + buffer)

        let start = rowInfos[firstRow].startIndex
        let lastRowInfo = rowInfos[lastRow]
        let end = min(totalItems, lastRowInfo.startIndex + lastRowInfo.count)
        return start ..< end
    }

    // MARK: - Transforms

    func transformForIndex(_ i: Int) -> simd_float4x4 {
        let (px, py, w, h) = itemRect(at: i)

        let ndcX = (px + w / 2.0) / viewportWidth * 2.0 - 1.0
        let ndcY = 1.0 - (py + h / 2.0) / viewportHeight * 2.0

        let sx = w / viewportWidth
        let sy = h / viewportHeight

        return simd_float4x4(
            SIMD4<Float>(sx, 0, 0, 0),
            SIMD4<Float>(0, sy, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(ndcX, ndcY, 0, 1)
        )
    }

    func outerHighlightTransformForIndex(_ i: Int) -> simd_float4x4 {
        let (px, py, w, h) = itemRect(at: i)
        let border: Float = 6.0

        let ndcX = (px + w / 2.0) / viewportWidth * 2.0 - 1.0
        let ndcY = 1.0 - (py + h / 2.0) / viewportHeight * 2.0

        let sx = (w + border * 2) / viewportWidth
        let sy = (h + border * 2) / viewportHeight

        return simd_float4x4(
            SIMD4<Float>(sx, 0, 0, 0),
            SIMD4<Float>(0, sy, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(ndcX, ndcY, 0, 1)
        )
    }

    func highlightTransformForIndex(_ i: Int) -> simd_float4x4 {
        let (px, py, w, h) = itemRect(at: i)
        let border: Float = 4.0

        let ndcX = (px + w / 2.0) / viewportWidth * 2.0 - 1.0
        let ndcY = 1.0 - (py + h / 2.0) / viewportHeight * 2.0

        let sx = (w + border * 2) / viewportWidth
        let sy = (h + border * 2) / viewportHeight

        return simd_float4x4(
            SIMD4<Float>(sx, 0, 0, 0),
            SIMD4<Float>(0, sy, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(ndcX, ndcY, 0, 1)
        )
    }

    func cellTransformForIndex(_ i: Int) -> simd_float4x4 {
        let (px, py, w, h) = itemRect(at: i)

        let ndcX = (px + w / 2.0) / viewportWidth * 2.0 - 1.0
        let ndcY = 1.0 - (py + h / 2.0) / viewportHeight * 2.0

        let sx = w / viewportWidth
        let sy = h / viewportHeight

        return simd_float4x4(
            SIMD4<Float>(sx, 0, 0, 0),
            SIMD4<Float>(0, sy, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(ndcX, ndcY, 0, 1)
        )
    }

    // MARK: - Row Helpers

    private func rowIndex(for itemIndex: Int) -> Int {
        ensureLayout()
        guard !rowInfos.isEmpty else { return 0 }
        var lo = 0, hi = rowInfos.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let row = rowInfos[mid]
            if itemIndex < row.startIndex {
                hi = mid - 1
            } else if itemIndex >= row.startIndex + row.count {
                lo = mid + 1
            } else {
                return mid
            }
        }
        return max(0, min(rowInfos.count - 1, lo))
    }

    private func closestItemInRow(_ ri: Int, toXCenter targetX: Float) -> Int {
        let row = rowInfos[ri]
        var bestIndex = row.startIndex
        var bestDist: Float = .greatestFiniteMagnitude
        for i in row.startIndex ..< (row.startIndex + row.count) {
            let rect = itemRects[i]
            let center = rect.x + rect.width / 2.0
            let dist = abs(center - targetX)
            if dist < bestDist {
                bestDist = dist
                bestIndex = i
            }
        }
        return bestIndex
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
        ensureLayout()
        guard !rowInfos.isEmpty else { return }
        let ri = rowIndex(for: selectedIndex)
        let row = rowInfos[ri]
        if selectedIndex > row.startIndex {
            selectedIndex -= 1
        }
        scrollToSelection()
    }

    func moveRight() {
        ensureLayout()
        guard !rowInfos.isEmpty else { return }
        let ri = rowIndex(for: selectedIndex)
        let row = rowInfos[ri]
        if selectedIndex < row.startIndex + row.count - 1 {
            selectedIndex += 1
        }
        scrollToSelection()
    }

    func moveUp() {
        ensureLayout()
        guard !rowInfos.isEmpty else { return }
        let ri = rowIndex(for: selectedIndex)
        guard ri > 0 else { return }
        let rect = itemRects[selectedIndex]
        let xCenter = rect.x + rect.width / 2.0
        selectedIndex = closestItemInRow(ri - 1, toXCenter: xCenter)
        scrollToSelection()
    }

    func moveDown() {
        ensureLayout()
        guard !rowInfos.isEmpty else { return }
        let ri = rowIndex(for: selectedIndex)
        guard ri < rowInfos.count - 1 else { return }
        let rect = itemRects[selectedIndex]
        let xCenter = rect.x + rect.width / 2.0
        selectedIndex = closestItemInRow(ri + 1, toXCenter: xCenter)
        scrollToSelection()
    }

    func pageUp() {
        ensureLayout()
        guard !rowInfos.isEmpty else { return }
        let ri = rowIndex(for: selectedIndex)

        var visibleHeight: Float = 0
        var targetRow = ri
        while targetRow > 0 {
            targetRow -= 1
            visibleHeight += rowInfos[targetRow].height + padding
            if visibleHeight >= viewportHeight { break }
        }

        let rect = itemRects[selectedIndex]
        let xCenter = rect.x + rect.width / 2.0
        selectedIndex = closestItemInRow(targetRow, toXCenter: xCenter)
        scrollToSelection()
    }

    func pageDown() {
        ensureLayout()
        guard !rowInfos.isEmpty else { return }
        let ri = rowIndex(for: selectedIndex)

        var visibleHeight: Float = 0
        var targetRow = ri
        while targetRow < rowInfos.count - 1 {
            targetRow += 1
            visibleHeight += rowInfos[targetRow].height + padding
            if visibleHeight >= viewportHeight { break }
        }

        let rect = itemRects[selectedIndex]
        let xCenter = rect.x + rect.width / 2.0
        selectedIndex = closestItemInRow(targetRow, toXCenter: xCenter)
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
        ensureLayout()
        guard selectedIndex >= 0, selectedIndex < itemRects.count else { return }
        let rect = itemRects[selectedIndex]
        let itemTop = rect.y
        let itemBottom = rect.y + rect.height

        if itemTop - selectionBorder < scrollOffset {
            scrollOffset = itemTop - selectionBorder
        }
        if itemBottom + selectionBorder > scrollOffset + viewportHeight {
            scrollOffset = itemBottom + selectionBorder - viewportHeight
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
