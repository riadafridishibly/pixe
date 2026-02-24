import Foundation

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
            guard let self = self else { return }
            let traversalStart = DispatchTime.now()

            if self.configuredWalkStrategyIsUnavailable(dirs.first?.config.walkStrategy) {
                DispatchQueue.main.async { [weak self] in
                    self?.sortAndReindex()
                }
                return
            }

            var totalFound = 0
            var perStrategyDirCount: [String: Int] = [:]
            for dir in dirs {
                if let result = self.enumerateDirectoryAsync(at: dir.path, config: dir.config) {
                    totalFound += result.fileCount
                    perStrategyDirCount[result.strategy, default: 0] += 1
                }
            }

            let strategySummary = perStrategyDirCount
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            let usedOnlyFD = perStrategyDirCount.count == 1 && perStrategyDirCount["fd"] == dirs.count
            MemoryProfiler.logPerf(
                String(
                    format: "traverse total %.1fms dirs=%d files=%d strategies=[%@] finalSort=%@",
                    elapsedMs(since: traversalStart),
                    dirs.count,
                    totalFound,
                    strategySummary,
                    usedOnlyFD ? "skip" : "sort"
                )
            )

            DispatchQueue.main.async { [weak self] in
                self?.sortAndReindex(shouldSort: !usedOnlyFD)
            }
        }
    }

    private func configuredWalkStrategyIsUnavailable(_ strategy: DirectoryWalkStrategy?) -> Bool {
        guard let strategy, strategy != .auto else { return false }
        guard !ImageDirectoryWalker.isAvailable(strategy) else { return false }
        fputs("pixe: traversal strategy '\(strategy.rawValue)' is unavailable\n", stderr)
        return true
    }

    private func enumerateDirectoryAsync(at path: String, config: Config) -> (strategy: String, fileCount: Int)? {
        let pendingMainBatches = DispatchGroup()
        let walkStart = DispatchTime.now()
        var foundCount = 0

        guard let strategy = ImageDirectoryWalker.walk(at: path, config: config, emitBatch: { [weak self] batch in
            guard !batch.isEmpty else { return }
            foundCount += batch.count
            pendingMainBatches.enter()
            DispatchQueue.main.async { [weak self] in
                defer { pendingMainBatches.leave() }
                self?.flushBatch(batch)
            }
        }) else {
            if config.walkStrategy == .auto {
                fputs("pixe: failed to traverse directory: \(path)\n", stderr)
            } else {
                fputs("pixe: failed to traverse directory with strategy '\(config.walkStrategy.rawValue)': \(path)\n", stderr)
            }
            return nil
        }

        pendingMainBatches.wait()
        MemoryProfiler.logPerf(
            String(
                format: "traverse %.1fms strategy=%@ files=%d path=%@",
                elapsedMs(since: walkStart),
                strategy,
                foundCount,
                path
            )
        )
        return (strategy: strategy, fileCount: foundCount)
    }

    private func flushBatch(_ batch: [String]) {
        let filtered = batch.filter { !deletedPaths.contains($0) }
        guard !filtered.isEmpty else { return }
        paths.append(contentsOf: filtered)
        onBatchAdded?(paths.count)
    }

    private func sortAndReindex(shouldSort: Bool = true) {
        if shouldSort {
            let currentPathBeforeSort = currentPath
            paths.sort()
            if let savedPath = currentPathBeforeSort,
               let newIndex = paths.firstIndex(of: savedPath) {
                currentIndex = newIndex
            } else if !paths.isEmpty {
                currentIndex = 0
            }
        } else if !paths.isEmpty {
            currentIndex = max(0, min(currentIndex, paths.count - 1))
        } else {
            currentIndex = 0
        }
        isEnumerating = false
        onEnumerationComplete?(paths.count)
    }

    private func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
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
