import Foundation
import UniformTypeIdentifiers

class ImageList {
    private var paths: [String] = []
    private(set) var currentIndex: Int = 0

    // Async enumeration state
    private(set) var isEnumerating: Bool = false
    private(set) var hasDirectoryArguments: Bool = false
    private var deletedPaths: Set<String> = []
    private var directoryArgs: [(path: String, config: Config)] = []

    // Callbacks for incremental updates
    var onBatchAdded: ((Int) -> Void)?
    var onEnumerationComplete: ((Int) -> Void)?

    var count: Int { paths.count }
    var isEmpty: Bool { paths.isEmpty }
    var allPaths: [String] { paths }

    var currentPath: String? {
        guard !paths.isEmpty else { return nil }
        return paths[currentIndex]
    }

    init(arguments: [String], config: Config) {
        let fileManager = FileManager.default

        for arg in arguments {
            let path: String
            if arg.hasPrefix("/") || arg.hasPrefix("~") {
                path = (arg as NSString).expandingTildeInPath
            } else {
                path = (fileManager.currentDirectoryPath as NSString).appendingPathComponent(arg)
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                fputs("pixe: \(arg): No such file or directory\n", stderr)
                continue
            }

            if isDirectory.boolValue {
                hasDirectoryArguments = true
                directoryArgs.append((path: path, config: config))
            } else {
                if ImageLoader.isImageFile(path) && config.extensionFilter.accepts(path) {
                    paths.append(path)
                }
            }
        }
    }

    func startEnumerationIfNeeded() {
        guard hasDirectoryArguments, !directoryArgs.isEmpty else { return }
        isEnumerating = true
        let dirs = directoryArgs
        directoryArgs = []

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for dir in dirs {
                self?.enumerateDirectoryAsync(at: dir.path, config: dir.config)
            }
            DispatchQueue.main.async { [weak self] in
                self?.sortAndReindex()
            }
        }
    }

    private func enumerateDirectoryAsync(at path: String, config: Config) {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        var staging: [String] = []
        var lastFlush = DispatchTime.now()
        let batchSize = 100
        let flushInterval: UInt64 = 200 * 1_000_000 // 200ms in nanoseconds

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  let isFile = values.isRegularFile, isFile,
                  let contentType = values.contentType,
                  contentType.conforms(to: .image) else {
                continue
            }
            guard config.extensionFilter.accepts(fileURL.path) else { continue }
            staging.append(fileURL.path)

            let elapsed = DispatchTime.now().uptimeNanoseconds - lastFlush.uptimeNanoseconds
            if staging.count >= batchSize || elapsed >= flushInterval {
                let batch = staging
                staging = []
                lastFlush = DispatchTime.now()
                DispatchQueue.main.sync { [weak self] in
                    self?.flushBatch(batch)
                }
            }
        }

        // Flush remaining
        if !staging.isEmpty {
            let batch = staging
            DispatchQueue.main.sync { [weak self] in
                self?.flushBatch(batch)
            }
        }
    }

    private func flushBatch(_ batch: [String]) {
        let filtered = batch.filter { !deletedPaths.contains($0) }
        guard !filtered.isEmpty else { return }
        paths.append(contentsOf: filtered)
        onBatchAdded?(paths.count)
    }

    private func sortAndReindex() {
        let currentPathBeforeSort = currentPath
        paths.sort()
        if let savedPath = currentPathBeforeSort,
           let newIndex = paths.firstIndex(of: savedPath) {
            currentIndex = newIndex
        } else if !paths.isEmpty {
            currentIndex = 0
        }
        isEnumerating = false
        onEnumerationComplete?(paths.count)
    }

    func goNext() {
        guard !paths.isEmpty else { return }
        currentIndex = (currentIndex + 1) % paths.count
    }

    func goPrevious() {
        guard !paths.isEmpty else { return }
        currentIndex = (currentIndex - 1 + paths.count) % paths.count
    }

    func goFirst() {
        currentIndex = 0
    }

    func goLast() {
        guard !paths.isEmpty else { return }
        currentIndex = paths.count - 1
    }

    func goTo(index: Int) {
        guard !paths.isEmpty else { return }
        currentIndex = max(0, min(index, paths.count - 1))
    }

    @discardableResult
    func remove(at index: Int) -> String? {
        guard index >= 0 && index < paths.count else { return nil }
        let removed = paths.remove(at: index)
        deletedPaths.insert(removed)
        if paths.isEmpty {
            currentIndex = 0
        } else if index < currentIndex {
            currentIndex -= 1
        } else if currentIndex >= paths.count {
            currentIndex = paths.count - 1
        }
        return removed
    }
}
