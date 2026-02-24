import Foundation
import ImageIO

class ImageList {
    private struct FileSignature {
        let mtime: Double
        let fileSize: Int64
    }

    private var paths: [String] = []
    private(set) var currentIndex: Int = 0
    private let sortMode: SortMode
    private let sortQueue = DispatchQueue(label: "pixe.sort", qos: .userInitiated)
    private var sortGeneration: Int = 0

    // Async enumeration state
    private(set) var isEnumerating: Bool = false
    private(set) var isSorting: Bool = false
    private(set) var hasDirectoryArguments: Bool = false
    private var deletedPaths: Set<String> = []
    private var knownPaths: Set<String> = []
    private var explicitFilePaths: Set<String> = []
    private var directoryArgs: [(path: String, config: Config)] = []
    private var exifDateCache: [String: ExifMetadataValue] = [:]
    private let metadataStore: MetadataStore?
    private var deferredDiscoveredPaths: [String] = []
    private var deferLiveBatchesUntilFinalSort = false

    // Callbacks for incremental updates
    var onBatchAdded: ((Int) -> Void)?
    var onEnumerationComplete: ((Int) -> Void)?

    var count: Int {
        paths.count
    }

    var isEmpty: Bool {
        paths.isEmpty
    }

    var allPaths: [String] {
        paths
    }

    var currentPath: String? {
        guard !paths.isEmpty else { return nil }
        return paths[currentIndex]
    }

    init(arguments: [String], config: Config) {
        sortMode = config.sortMode
        metadataStore = config.diskCacheEnabled ? MetadataStore(directory: config.thumbDir) : nil
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
                if let cached = metadataStore?.cachedDirectoryEntries(dirPath: path, filter: config.extensionFilter) {
                    for cachedPath in cached where !deletedPaths.contains(cachedPath) {
                        if knownPaths.insert(cachedPath).inserted {
                            paths.append(cachedPath)
                        }
                    }
                }
            } else {
                if ImageLoader.isImageFile(path) && config.extensionFilter.accepts(path) {
                    if knownPaths.insert(path).inserted {
                        paths.append(path)
                        explicitFilePaths.insert(path)
                    }
                }
            }
        }

        if hasDirectoryArguments, !paths.isEmpty {
            paths = sortPathsWithCachedMetadata(paths, mode: sortMode)
            deferLiveBatchesUntilFinalSort = true
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
                    self?.isEnumerating = false
                    self?.finalizeList(shouldSort: self?.sortMode.requiresExplicitSort ?? false)
                }
                return
            }

            var totalFound = 0
            var perStrategyDirCount: [String: Int] = [:]
            var discoveredByDirectory: [(dirPath: String, discovered: Set<String>)] = []
            for dir in dirs {
                if let result = self.enumerateDirectoryAsync(at: dir.path, config: dir.config) {
                    totalFound += result.fileCount
                    perStrategyDirCount[result.strategy, default: 0] += 1
                    discoveredByDirectory.append((dirPath: dir.path, discovered: Set(result.discoveredPaths)))
                }
            }

            let strategySummary = perStrategyDirCount
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            let usedOnlyFD = perStrategyDirCount.count == 1 && perStrategyDirCount["fd"] == dirs.count
            let shouldSort = self.sortMode.requiresExplicitSort || !usedOnlyFD
            MemoryProfiler.logPerf(
                String(
                    format: "traverse total %.1fms dirs=%d files=%d strategies=[%@] finalSort=%@",
                    elapsedMs(since: traversalStart),
                    dirs.count,
                    totalFound,
                    strategySummary,
                    shouldSort ? self.sortMode.rawValue : "skip"
                )
            )

            DispatchQueue.main.async { [weak self] in
                self?.reconcileScannedDirectories(discoveredByDirectory)
                self?.isEnumerating = false
                self?.finalizeList(shouldSort: shouldSort)
            }
        }
    }

    func startInitialSortIfNeeded() {
        guard !hasDirectoryArguments, sortMode.requiresExplicitSort, paths.count > 1 else { return }
        finalizeList(shouldSort: true)
    }

    private func configuredWalkStrategyIsUnavailable(_ strategy: DirectoryWalkStrategy?) -> Bool {
        guard let strategy, strategy != .auto else { return false }
        guard !ImageDirectoryWalker.isAvailable(strategy) else { return false }
        fputs("pixe: traversal strategy '\(strategy.rawValue)' is unavailable\n", stderr)
        return true
    }

    private func enumerateDirectoryAsync(
        at path: String,
        config: Config
    ) -> (strategy: String, fileCount: Int, discoveredPaths: [String])? {
        let pendingMainBatches = DispatchGroup()
        let walkStart = DispatchTime.now()
        var foundCount = 0
        var discoveredPaths: [String] = []

        guard let strategy = ImageDirectoryWalker.walk(at: path, config: config, emitBatch: { [weak self] batch in
            guard !batch.isEmpty else { return }
            foundCount += batch.count
            discoveredPaths.append(contentsOf: batch)
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
        metadataStore?.replaceDirectoryEntries(dirPath: path, paths: discoveredPaths)
        MemoryProfiler.logPerf(
            String(
                format: "traverse %.1fms strategy=%@ files=%d path=%@",
                elapsedMs(since: walkStart),
                strategy,
                foundCount,
                path
            )
        )
        return (strategy: strategy, fileCount: foundCount, discoveredPaths: discoveredPaths)
    }

    private func flushBatch(_ batch: [String]) {
        let filtered = batch.filter { !deletedPaths.contains($0) && knownPaths.insert($0).inserted }
        guard !filtered.isEmpty else { return }

        if deferLiveBatchesUntilFinalSort {
            deferredDiscoveredPaths.append(contentsOf: filtered)
            return
        }

        paths.append(contentsOf: filtered)
        onBatchAdded?(paths.count)
    }

    private func reconcileScannedDirectories(_ scanned: [(dirPath: String, discovered: Set<String>)]) {
        guard !scanned.isEmpty else { return }
        let reconciled = paths.filter { path in
            if explicitFilePaths.contains(path) {
                return true
            }
            for entry in scanned where isPath(path, insideDirectory: entry.dirPath) {
                if entry.discovered.contains(path) {
                    return true
                }
                return false
            }
            return true
        }
        paths = reconciled
        knownPaths = Set(reconciled)
        clampCurrentIndex()
    }

    private func isPath(_ path: String, insideDirectory dir: String) -> Bool {
        if path == dir {
            return true
        }
        let normalizedDir = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        return path.hasPrefix(normalizedDir + "/")
    }

    private func finalizeList(shouldSort: Bool) {
        if !deferredDiscoveredPaths.isEmpty {
            paths.append(contentsOf: deferredDiscoveredPaths)
            deferredDiscoveredPaths.removeAll(keepingCapacity: true)
        }
        let effectiveShouldSort = shouldSort || deferLiveBatchesUntilFinalSort

        guard effectiveShouldSort else {
            sortGeneration += 1
            isSorting = false
            clampCurrentIndex()
            deferLiveBatchesUntilFinalSort = false
            onEnumerationComplete?(paths.count)
            return
        }

        isSorting = true
        sortGeneration += 1
        let generation = sortGeneration
        let snapshot = paths
        let requestCurrentPath = currentPath
        let sortMode = self.sortMode

        sortQueue.async { [weak self] in
            guard let self = self else { return }
            let sorted = self.sortedPaths(snapshot, mode: sortMode)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard generation == self.sortGeneration else { return }
                self.applySortedPaths(sorted, preferredPath: self.currentPath ?? requestCurrentPath)
            }
        }
    }

    private func sortedPaths(_ input: [String], mode: SortMode) -> [String] {
        var sorted = input
        switch mode {
        case .name:
            sorted.sort()
        case .chrono:
            sortByExifDate(paths: &sorted, reverse: false)
        case .reverseChrono:
            sortByExifDate(paths: &sorted, reverse: true)
        }
        return sorted
    }

    private func applySortedPaths(_ sorted: [String], preferredPath: String?) {
        let filtered = sorted.filter { !deletedPaths.contains($0) }
        paths = filtered
        knownPaths = Set(filtered)

        if let preferredPath, let index = paths.firstIndex(of: preferredPath) {
            currentIndex = index
        } else {
            clampCurrentIndex()
        }

        isSorting = false
        deferLiveBatchesUntilFinalSort = false
        onEnumerationComplete?(paths.count)
    }

    private func clampCurrentIndex() {
        if !paths.isEmpty {
            currentIndex = max(0, min(currentIndex, paths.count - 1))
        } else {
            currentIndex = 0
        }
    }

    private func sortByExifDate(paths: inout [String], reverse: Bool) {
        var exifValuesByPath: [String: ExifMetadataValue] = [:]
        exifValuesByPath.reserveCapacity(paths.count)
        for path in paths where exifValuesByPath[path] == nil {
            exifValuesByPath[path] = exifCaptureMetadata(for: path)
        }

        paths.sort { lhs, rhs in
            let lhsDate = exifDate(from: exifValuesByPath[lhs] ?? .missing)
            let rhsDate = exifDate(from: exifValuesByPath[rhs] ?? .missing)

            switch (lhsDate, rhsDate) {
            case let (lhs?, rhs?):
                if lhs != rhs {
                    return reverse ? lhs > rhs : lhs < rhs
                }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }

            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private func sortPathsWithCachedMetadata(_ input: [String], mode: SortMode) -> [String] {
        guard mode.requiresExplicitSort else {
            return input.sorted()
        }
        var sorted = input
        var cachedByPath: [String: ExifMetadataValue] = [:]
        cachedByPath.reserveCapacity(sorted.count)
        for path in sorted where cachedByPath[path] == nil {
            cachedByPath[path] = metadataStore?.cachedExifWithoutSignature(path: path) ?? .missing
        }
        let reverse = mode == .reverseChrono
        sorted.sort { lhs, rhs in
            let lhsDate = exifDate(from: cachedByPath[lhs] ?? .missing)
            let rhsDate = exifDate(from: cachedByPath[rhs] ?? .missing)

            switch (lhsDate, rhsDate) {
            case let (lhs?, rhs?):
                if lhs != rhs {
                    return reverse ? lhs > rhs : lhs < rhs
                }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return sorted
    }

    private func exifDate(from value: ExifMetadataValue) -> Date? {
        switch value {
        case .missing:
            return nil
        case let .date(date):
            return date
        }
    }

    private func exifCaptureMetadata(for path: String) -> ExifMetadataValue {
        if let cached = exifDateCache[path] {
            return cached
        }

        let signature = fileSignature(for: path)
        if let signature,
           let persisted = metadataStore?.cachedExif(
               path: path,
               mtime: signature.mtime,
               fileSize: signature.fileSize
           )
        {
            exifDateCache[path] = persisted
            return persisted
        }

        let parsedDate = Self.readExifCaptureDate(for: path)
        let parsedMetadata: ExifMetadataValue = parsedDate.map { .date($0) } ?? .missing
        exifDateCache[path] = parsedMetadata
        if let signature {
            metadataStore?.upsertExif(
                path: path,
                mtime: signature.mtime,
                fileSize: signature.fileSize,
                captureDate: parsedDate
            )
        }
        return parsedMetadata
    }

    private func fileSignature(for path: String) -> FileSignature? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date,
              let rawSize = attrs[.size] as? NSNumber
        else {
            return nil
        }
        return FileSignature(
            mtime: modDate.timeIntervalSince1970,
            fileSize: rawSize.int64Value
        )
    }

    private static func readExifCaptureDate(for path: String) -> Date? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return nil
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if let date = parseExifDate(exif[kCGImagePropertyExifDateTimeOriginal]) {
            return date
        }
        if let date = parseExifDate(exif[kCGImagePropertyExifDateTimeDigitized]) {
            return date
        }

        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        if let date = parseExifDate(tiff[kCGImagePropertyTIFFDateTime]) {
            return date
        }
        return nil
    }

    private static func parseExifDate(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        for formatter in exifDateFormatters {
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }

    private static let exifDateFormatters: [DateFormatter] = {
        func makeFormatter(_ format: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }

        return [
            makeFormatter("yyyy:MM:dd HH:mm:ss"),
            makeFormatter("yyyy:MM:dd HH:mm:ssZ"),
            makeFormatter("yyyy:MM:dd HH:mm:ssXXXXX"),
            makeFormatter("yyyy-MM-dd HH:mm:ss"),
            makeFormatter("yyyy-MM-dd HH:mm:ssZ"),
            makeFormatter("yyyy-MM-dd'T'HH:mm:ss"),
            makeFormatter("yyyy-MM-dd'T'HH:mm:ssZ"),
            makeFormatter("yyyy-MM-dd'T'HH:mm:ssXXXXX")
        ]
    }()

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
        knownPaths.remove(removed)
        exifDateCache.removeValue(forKey: removed)
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
