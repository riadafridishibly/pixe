import AppKit
import MetalKit

extension Renderer {
    func updateWindowTitle() {
        let isScanning = imageList.isEnumerating
        let isSorting = imageList.isSorting
        switch mode {
        case .image:
            guard let path = imageList.currentPath else { return }
            let filename = (path as NSString).lastPathComponent
            window?.updateTitle(filename: filename, index: imageList.currentIndex, total: imageList.count)
        case .thumbnail:
            if isScanning {
                window?.title = "pixe [\(imageList.count) images] scanning..."
            } else if isSorting {
                window?.title = "pixe [\(imageList.count) images] sorting..."
            } else {
                window?.title = "pixe [\(imageList.count) images]"
            }
        }
        updateInfoBar()
    }

    // MARK: - Memory Profiling

    func generateMemoryReport() {
        var prefetchEntries: [(path: String, size: Int, dims: String)] = []
        for (path, entry) in prefetchCache {
            let size = MemoryProfiler.textureBytes(entry.texture)
            let dims = "\(entry.texture.width)×\(entry.texture.height)"
            prefetchEntries.append((path: path, size: size, dims: dims))
        }

        var thumbCount = 0
        var thumbTotalBytes = 0
        if let cache = thumbnailCache {
            let snapshot = cache.textureSnapshot()
            thumbCount = snapshot.count
            for tex in snapshot {
                thumbTotalBytes += MemoryProfiler.textureBytes(tex)
            }
        }

        var currentInfo: String?
        if let tex = currentTexture {
            currentInfo = MemoryProfiler.textureSummary(tex)
        }

        let report = MemoryProfiler.Report(
            rss: MemoryProfiler.residentMemoryBytes(),
            virtual: MemoryProfiler.virtualMemoryBytes(),
            metalAllocated: MemoryProfiler.metalAllocatedSize(device),
            prefetchEntries: prefetchEntries,
            thumbnailCount: thumbCount,
            thumbnailTotalBytes: thumbTotalBytes,
            currentTextureInfo: currentInfo
        )
        MemoryProfiler.printReport(report)
    }

    func updateInfoBar() {
        hideImageInfo()
        let isScanning = imageList.isEnumerating
        let isSorting = imageList.isSorting
        switch mode {
        case .thumbnail:
            if imageList.allPaths.isEmpty {
                if isScanning {
                    window?.updateInfo("scanning...")
                } else if isSorting {
                    window?.updateInfo("sorting...")
                }
                return
            }
            let index = gridLayout.selectedIndex
            let path = imageList.allPaths[min(index, imageList.allPaths.count - 1)]
            let suffix: String
            if isScanning {
                suffix = " scanning..."
            } else if isSorting {
                suffix = " sorting..."
            } else {
                suffix = ""
            }
            var text: String
            if let query = thumbnailSearchQuery {
                text = query.isEmpty ? "/" : "/\(query)"
            } else {
                let totalWidth = String(imageList.count).count
                let padded = String(repeating: " ", count: totalWidth - String(index + 1).count) + "\(index + 1)"
                text = "[\(padded)/\(imageList.count)]\(suffix) \(shortenPath(path))"
            }
            if imageList.isShuffled { text += " [shuffle]" }
            window?.updateInfo(text)
        case .image:
            guard let path = imageList.currentPath else { return }
            let totalWidth = String(imageList.count).count
            let padded = String(repeating: " ", count: totalWidth - String(imageList.currentIndex + 1).count) + "\(imageList.currentIndex + 1)"
            var text = "[\(padded)/\(imageList.count)] \(path)"
            if let tex = currentTexture {
                text += " \u{2014} \(tex.width) \u{00D7} \(tex.height)"
            }
            if imageList.isShuffled { text += " [shuffle]" }
            if isAutoplayActive { text += " [autoplay]" }
            window?.updateInfo(text)
        }
        updateThumbnailGIFIfNeeded()
    }

    func setThumbnailSearchQuery(_ query: String?) {
        thumbnailSearchQuery = query
        updateInfoBar()
    }

    private func shortenPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Reveal in Finder

    func revealInFinder() {
        let path: String?
        switch mode {
        case .thumbnail:
            let index = gridLayout.selectedIndex
            guard index < imageList.allPaths.count else { return }
            path = imageList.allPaths[index]
        case .image:
            path = imageList.currentPath
        }
        guard let filePath = path else { return }
        NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: "")
    }

    // MARK: - Image Info Panel

    func toggleImageInfo() {
        let path: String?
        switch mode {
        case .thumbnail:
            let index = gridLayout.selectedIndex
            guard index < imageList.allPaths.count else { return }
            path = imageList.allPaths[index]
        case .image:
            path = imageList.currentPath
        }
        guard let filePath = path else { return }
        let metadata = ImageLoader.imageMetadata(path: filePath)
        let text = metadata.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        window?.toggleInfoPanel(text)
    }

    func hideImageInfo() {
        window?.hideInfoPanel()
    }

    // MARK: - Delete Image

    func deleteImage(at index: Int) {
        guard index >= 0 && index < imageList.count else { return }
        let path = imageList.allPaths[index]
        guard let window = window else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move to Trash?"
        alert.informativeText = path
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        if let nsImage = NSImage(contentsOfFile: path) {
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
            imageView.image = nsImage
            imageView.imageScaling = .scaleProportionallyUpOrDown
            alert.accessoryView = imageView
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.performDeletion(at: index, path: path)
            }
        }
    }

    private func performDeletion(at index: Int, path: String) {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            let errorAlert = NSAlert()
            errorAlert.alertStyle = .critical
            errorAlert.messageText = "Failed to move to Trash"
            errorAlert.informativeText = error.localizedDescription
            errorAlert.runModal()
            return
        }

        imageList.remove(at: index)

        if imageList.isEmpty {
            NSApp.terminate(nil)
            return
        }

        thumbnailCache?.invalidateAll()
        prefetchCache.removeValue(forKey: path)

        gridLayout.resetAspects()
        aspectPreloadedCount = 0
        gridLayout.totalItems = imageList.count
        if gridLayout.selectedIndex >= imageList.count {
            gridLayout.selectedIndex = imageList.count - 1
        }

        switch mode {
        case .thumbnail:
            stopScrollAnimation()
            gridLayout.scrollToSelection()
            updateWindowTitle()
            if let view = window?.contentView as? MTKView { view.needsDisplay = true }
        case .image:
            loadCurrentImage()
        }
    }

    // MARK: - Clipboard

    func copyCurrentImage() {
        guard let path = currentImagePath() else { return }
        guard let nsImage = NSImage(contentsOfFile: path) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
        showTemporaryInfo("Copied image to clipboard")
    }

    func copyCurrentImagePath() {
        guard let path = currentImagePath() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        showTemporaryInfo("Copied path to clipboard")
    }

    private func currentImagePath() -> String? {
        switch mode {
        case .thumbnail:
            let index = gridLayout.selectedIndex
            guard index < imageList.allPaths.count else { return nil }
            return imageList.allPaths[index]
        case .image:
            return imageList.currentPath
        }
    }

    private func showTemporaryInfo(_ message: String) {
        infoRestoreWorkItem?.cancel()
        window?.updateInfo(message)
        let item = DispatchWorkItem { [weak self] in
            self?.updateInfoBar()
        }
        infoRestoreWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    // MARK: - Shuffle

    func toggleShuffle() {
        if imageList.isShuffled {
            imageList.unshuffle()
        } else {
            imageList.shuffle()
        }
        thumbnailCache?.invalidateAll()
        gridLayout.resetAspects()
        aspectPreloadedCount = 0
        gridLayout.totalItems = imageList.count
        preloadAspectsAsync(from: 0)
        if mode == .thumbnail {
            stopScrollAnimation()
            gridLayout.selectedIndex = imageList.currentIndex
            gridLayout.scrollToSelection()
        }
        prefetchCache.removeAll()
        updateWindowTitle()
        if let view = window?.contentView as? MTKView {
            view.needsDisplay = true
        }
    }

    // MARK: - Ignore Folder

    func ignoreCurrentFolder() {
        let filePath: String?
        let activeIndex: Int
        switch mode {
        case .thumbnail:
            activeIndex = gridLayout.selectedIndex
            guard activeIndex < imageList.allPaths.count else { return }
            filePath = imageList.allPaths[activeIndex]
        case .image:
            activeIndex = imageList.currentIndex
            filePath = imageList.currentPath
        }
        guard let filePath else { return }

        let directory = (filePath as NSString).deletingLastPathComponent
        let dirName = (directory as NSString).lastPathComponent
        let removed = imageList.removePathsInDirectory(directory)
        guard removed > 0 else { return }

        if imageList.isEmpty {
            NSApp.terminate(nil)
            return
        }

        thumbnailCache?.invalidateAll()
        gridLayout.resetAspects()
        aspectPreloadedCount = 0
        gridLayout.totalItems = imageList.count
        preloadAspectsAsync(from: 0)
        prefetchCache.removeAll()

        switch mode {
        case .thumbnail:
            stopScrollAnimation()
            gridLayout.selectedIndex = min(activeIndex, imageList.count - 1)
            gridLayout.scrollToSelection()
        case .image:
            loadCurrentImage()
        }

        updateWindowTitle()
        showTemporaryInfo("Ignored \(dirName)/ (\(removed) images)")
        if let view = window?.contentView as? MTKView {
            view.needsDisplay = true
        }
    }
}
