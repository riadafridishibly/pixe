import CommonCrypto
import Foundation
import Metal

// MARK: - O(1) LRU via doubly-linked list

private class LRUNode {
    let key: Int
    var prev: LRUNode?
    var next: LRUNode?
    init(key: Int) {
        self.key = key
    }
}

private class LRUList {
    private var head: LRUNode?  // oldest
    private var tail: LRUNode?  // newest
    private var map: [Int: LRUNode] = [:]

    var count: Int {
        map.count
    }

    func touch(_ key: Int) {
        if let node = map[key] {
            remove(node)
            appendTail(node)
        } else {
            let node = LRUNode(key: key)
            map[key] = node
            appendTail(node)
        }
    }

    func evictOldest() -> Int? {
        guard let node = head else { return nil }
        remove(node)
        map.removeValue(forKey: node.key)
        return node.key
    }

    func removeKey(_ key: Int) {
        guard let node = map.removeValue(forKey: key) else { return }
        remove(node)
    }

    func removeAll() {
        head = nil
        tail = nil
        map.removeAll()
    }

    private func remove(_ node: LRUNode) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
        node.prev = nil
        node.next = nil
    }

    private func appendTail(_ node: LRUNode) {
        node.prev = tail
        node.next = nil
        tail?.next = node
        tail = node
        if head == nil { head = node }
    }
}

// MARK: - ThumbnailCache

class ThumbnailCache {
    let device: MTLDevice
    let baseMaxCached: Int = 300
    let hardMaxCached: Int = 1800
    let maxPixelSize: Int

    // In-memory texture cache
    private var cache: [Int: MTLTexture] = [:]
    private(set) var aspects: [Int: Float] = [:]
    private var loading: Set<Int> = []
    private let lru = LRUList()
    private var dynamicMaxCached: Int
    private var pinnedVisibleRange: Range<Int> = 0 ..< 0

    // Disk cache
    private let diskCacheEnabled: Bool
    private let thumbDir: String
    private let metadataStore: MetadataStore?

    // Concurrency
    private let loadQueue = DispatchQueue(label: "pixe.thumbnail", qos: .utility, attributes: .concurrent)
    private let loadSemaphore = DispatchSemaphore(value: 8)
    private var currentGeneration: Int = 0
    private var currentPrefetchRange: Range<Int> = 0 ..< 0
    private var currentListVersion: Int = 0
    private let stateLock = NSLock()

    // Disk serialization
    private let diskQueue = DispatchQueue(label: "pixe.disk-cache", qos: .utility)

    init(device: MTLDevice, config: Config) {
        self.device = device
        maxPixelSize = config.thumbSize
        dynamicMaxCached = baseMaxCached
        diskCacheEnabled = config.diskCacheEnabled
        thumbDir = config.thumbDir
        metadataStore = config.diskCacheEnabled ? MetadataStore(directory: config.thumbDir) : nil

        if diskCacheEnabled {
            ensureDirectory(thumbDir)
            diskQueue.async { [weak self] in
                self?.cleanOrphanedFiles()
            }
        }
    }

    // MARK: - Public API

    func texture(at index: Int) -> MTLTexture? {
        if let tex = cache[index] {
            lru.touch(index)
            return tex
        }
        return nil
    }

    func aspect(at index: Int) -> Float {
        return aspects[index] ?? 1.0
    }

    func ensureLoaded(indices: Range<Int>, pinnedIndices: Range<Int>, paths: [String], completion: @escaping () -> Void) {
        // Called from main thread only
        updateDynamicBudget(prefetch: indices, pinned: pinnedIndices, totalPathCount: paths.count)

        var toLoad: [(Int, String)] = []
        for i in indices {
            guard i < paths.count else { continue }
            if cache[i] != nil || loading.contains(i) { continue }
            loading.insert(i)
            toLoad.append((i, paths[i]))
        }

        stateLock.lock()
        currentGeneration += 1
        currentPrefetchRange = indices
        let generation = currentGeneration
        let listVersion = currentListVersion
        stateLock.unlock()

        guard !toLoad.isEmpty else {
            evictIfNeeded()
            return
        }

        let device = self.device
        let maxPixelSize = self.maxPixelSize
        let diskEnabled = diskCacheEnabled

        for (index, path) in toLoad {
            loadQueue.async { [weak self] in
                // Pre-semaphore stale check: skip if user scrolled past
                if let self = self {
                    self.stateLock.lock()
                    let isStale =
                        self.currentListVersion != listVersion ||
                        (self.currentGeneration != generation && !self.currentPrefetchRange.contains(index))
                    self.stateLock.unlock()
                    if isStale {
                        DispatchQueue.main.async { self.loading.remove(index) }
                        return
                    }
                }

                self?.loadSemaphore.wait()
                let thumbStart = DispatchTime.now()

                // Post-semaphore stale check: may have become stale while waiting
                if let self = self {
                    self.stateLock.lock()
                    let isStale =
                        self.currentListVersion != listVersion ||
                        (self.currentGeneration != generation && !self.currentPrefetchRange.contains(index))
                    self.stateLock.unlock()
                    if isStale {
                        self.loadSemaphore.signal()
                        DispatchQueue.main.async { self.loading.remove(index) }
                        return
                    }
                }

                let cacheKey = diskEnabled ? Self.cacheKey(for: path) : nil
                var texture: MTLTexture?
                var aspect: Float = 1.0
                var cacheData: Data?
                var sourceMtime: Double = 0
                var perfDetail = ""

                // Try disk cache first
                if diskEnabled, let key = cacheKey {
                    if let entry = self?.metadataStore?.thumbnail(forKey: key) {
                        let diskStart = DispatchTime.now()
                        if let diskPath = self?.diskPath(for: key),
                           let data = try? Data(contentsOf: URL(fileURLWithPath: diskPath)),
                           let result = ImageLoader.textureFromJPEGData(data, device: device),
                           result.width == entry.width, result.height == entry.height
                        {
                            texture = result.texture
                            aspect = entry.aspect
                            let diskMs = Double(DispatchTime.now().uptimeNanoseconds - diskStart.uptimeNanoseconds) / 1_000_000
                            perfDetail = String(format: "disk+decode %.1fms", diskMs)
                        } else {
                            self?.metadataStore?.removeThumbnail(forKey: key)
                        }
                    }
                }

                // Generate fresh thumbnail if no cache hit
                if texture == nil {
                    let genStart = DispatchTime.now()
                    if let result = ImageLoader.generateThumbnail(
                        path: path, device: device, maxPixelSize: maxPixelSize
                    ) {
                        texture = result.texture
                        aspect = result.aspect
                        cacheData = result.cacheData
                        sourceMtime = Self.fileModTime(path)
                        let genMs = Double(DispatchTime.now().uptimeNanoseconds - genStart.uptimeNanoseconds) / 1_000_000
                        perfDetail = String(format: "generate %.1fms", genMs)
                    }
                }

                self?.loadSemaphore.signal()

                let totalMs = Double(DispatchTime.now().uptimeNanoseconds - thumbStart.uptimeNanoseconds) / 1_000_000
                let source = cacheData != nil ? "gen" : "hit"
                MemoryProfiler.logPerf(String(format: "thumb %d %@ %.1fms (%@)", index, source, totalMs, perfDetail))

                // Deliver this thumbnail immediately to main thread
                if let texture = texture {
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.cache[index] = texture
                        self.aspects[index] = aspect
                        self.loading.remove(index)
                        self.lru.touch(index)

                        // Write to disk cache in background
                        if diskEnabled, let cacheData = cacheData, let key = cacheKey {
                            let diskPath = self.diskPath(for: key)
                            let width = texture.width
                            let height = texture.height
                            let aspect = aspect
                            let sourcePath = path
                            let sourceMtime = sourceMtime
                            self.diskQueue.async {
                                self.writeDiskCache(data: cacheData, to: diskPath)
                                self.metadataStore?.upsertThumbnail(
                                    key: key,
                                    sourcePath: sourcePath,
                                    sourceMtime: sourceMtime,
                                    width: width,
                                    height: height,
                                    aspect: aspect
                                )
                            }
                        }

                        self.evictIfNeeded()
                        completion()
                    }
                } else {
                    DispatchQueue.main.async {
                        self?.loading.remove(index)
                    }
                }
            }
        }
    }

    /// Returns all cached textures for memory profiling
    func textureSnapshot() -> [MTLTexture] {
        return Array(cache.values)
    }

    func invalidateAll() {
        cache.removeAll()
        aspects.removeAll()
        lru.removeAll()
        loading.removeAll()
        dynamicMaxCached = baseMaxCached
        pinnedVisibleRange = 0 ..< 0
        stateLock.lock()
        currentGeneration += 1
        currentPrefetchRange = 0 ..< 0
        currentListVersion += 1
        stateLock.unlock()
    }

    // MARK: - LRU Eviction

    private func evictIfNeeded() {
        while cache.count > dynamicMaxCached {
            let maxAttempts = lru.count
            var attempts = 0
            var evicted = false

            while attempts < maxAttempts, let oldest = lru.evictOldest() {
                attempts += 1
                if pinnedVisibleRange.contains(oldest) {
                    // Keep visible thumbnails resident to prevent flicker.
                    lru.touch(oldest)
                    continue
                }
                cache.removeValue(forKey: oldest)
                aspects.removeValue(forKey: oldest)
                evicted = true
                break
            }

            // All remaining entries are pinned-visible; stop evicting.
            if !evicted { break }
        }
    }

    private func updateDynamicBudget(prefetch: Range<Int>, pinned: Range<Int>, totalPathCount: Int) {
        pinnedVisibleRange = pinned

        let needed = max(prefetch.count, pinned.count)
        let withSlack = needed + max(32, needed / 8)
        let target = min(max(totalPathCount, baseMaxCached), hardMaxCached)
        let newBudget = min(target, max(baseMaxCached, withSlack))
        dynamicMaxCached = newBudget
    }

    // MARK: - Disk Cache

    static func cacheKey(for path: String) -> String {
        let mtime = fileModTime(path)
        let input = "\(path):\(mtime)"
        return sha256(input)
    }

    static func fileModTime(_ path: String) -> Double {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date
        else {
            return 0
        }
        return date.timeIntervalSince1970
    }

    static func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    static func diskPath(for key: String, thumbDir: String) -> String {
        let subdir = (thumbDir as NSString).appendingPathComponent(String(key.prefix(2)))
        return (subdir as NSString).appendingPathComponent(key + ".jpg")
    }

    private func diskPath(for key: String) -> String {
        let path = Self.diskPath(for: key, thumbDir: thumbDir)
        let subdir = (path as NSString).deletingLastPathComponent
        ensureDirectory(subdir)
        return path
    }

    private func writeDiskCache(data: Data, to path: String) {
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func ensureDirectory(_ path: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }

    // MARK: - Orphan Cleanup

    private func cleanOrphanedFiles() {
        let fm = FileManager.default
        let metadataKeys: Set<String> = metadataStore?.allThumbnailKeys() ?? []
        let legacyManifestPath = (thumbDir as NSString).appendingPathComponent("manifest.json")
        if fm.fileExists(atPath: legacyManifestPath) {
            try? fm.removeItem(atPath: legacyManifestPath)
        }
        guard let subdirs = try? fm.contentsOfDirectory(atPath: thumbDir) else { return }
        for subdir in subdirs {
            let subdirPath = (thumbDir as NSString).appendingPathComponent(subdir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: subdirPath, isDirectory: &isDir), isDir.boolValue,
                  subdir.count == 2 else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: subdirPath) else { continue }
            for file in files {
                let filePath = (subdirPath as NSString).appendingPathComponent(file)
                if file.hasSuffix(".raw") {
                    // Legacy format — always remove
                    try? fm.removeItem(atPath: filePath)
                } else if file.hasSuffix(".jpg") {
                    let key = String(file.dropLast(4))  // remove ".jpg"
                    if !metadataKeys.contains(key) {
                        try? fm.removeItem(atPath: filePath)
                    }
                }
            }
        }
    }

    func flushManifest() {
        diskQueue.sync {}
        metadataStore?.flush()
    }
}
