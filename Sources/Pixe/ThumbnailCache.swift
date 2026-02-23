import Metal
import Foundation
import CommonCrypto

// MARK: - O(1) LRU via doubly-linked list

private class LRUNode {
    let key: Int
    var prev: LRUNode?
    var next: LRUNode?
    init(key: Int) { self.key = key }
}

private class LRUList {
    private var head: LRUNode?  // oldest
    private var tail: LRUNode?  // newest
    private var map: [Int: LRUNode] = [:]

    var count: Int { map.count }

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

// MARK: - Disk manifest entry

private struct ManifestEntry: Codable {
    let width: Int
    let height: Int
    let aspect: Float
    let mtime: Double  // source file modification time
}

// MARK: - ThumbnailCache

class ThumbnailCache {
    let device: MTLDevice
    let maxCached: Int = 300
    let maxPixelSize: Int

    // In-memory texture cache
    private var cache: [Int: MTLTexture] = [:]
    private(set) var aspects: [Int: Float] = [:]
    private var loading: Set<Int> = []
    private let lru = LRUList()

    // Disk cache
    private let diskCacheEnabled: Bool
    private let thumbDir: String
    private var manifest: [String: ManifestEntry] = [:]
    private let manifestPath: String
    private var manifestDirty = false

    // Concurrency
    private let loadQueue = DispatchQueue(label: "pixe.thumbnail", qos: .utility, attributes: .concurrent)
    private let loadSemaphore = DispatchSemaphore(value: 4)
    private var currentGeneration: Int = 0
    private var currentPrefetchRange: Range<Int> = 0..<0
    private let stateLock = NSLock()

    // Manifest serialization
    private let manifestQueue = DispatchQueue(label: "pixe.manifest", qos: .utility)
    private var pendingManifestSave: DispatchWorkItem?

    init(device: MTLDevice, config: Config) {
        self.device = device
        self.maxPixelSize = config.thumbSize
        self.diskCacheEnabled = config.diskCacheEnabled
        self.thumbDir = config.thumbDir
        self.manifestPath = (config.thumbDir as NSString).appendingPathComponent("manifest.json")

        if diskCacheEnabled {
            ensureDirectory(thumbDir)
            loadManifest()
            let manifestKeysSnapshot = Set(manifest.keys)
            loadQueue.async { [weak self] in
                self?.cleanOrphanedFiles(manifestKeys: manifestKeysSnapshot)
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

    func ensureLoaded(indices: Range<Int>, paths: [String], completion: @escaping () -> Void) {
        // Called from main thread only
        var toLoad: [(Int, String)] = []
        for i in indices {
            guard i < paths.count else { continue }
            if cache[i] != nil || loading.contains(i) { continue }
            loading.insert(i)
            toLoad.append((i, paths[i]))
        }

        guard !toLoad.isEmpty else { return }

        stateLock.lock()
        currentGeneration += 1
        currentPrefetchRange = indices
        let generation = currentGeneration
        stateLock.unlock()
        let device = self.device
        let maxPixelSize = self.maxPixelSize
        let diskEnabled = self.diskCacheEnabled
        let manifestSnapshot = diskEnabled ? self.manifest : [:]

        loadQueue.async { [weak self] in
            for (index, path) in toLoad {
                // Pre-semaphore stale check: skip if user scrolled past
                if let self = self {
                    self.stateLock.lock()
                    let isStale = self.currentGeneration != generation && !self.currentPrefetchRange.contains(index)
                    self.stateLock.unlock()
                    if isStale {
                        DispatchQueue.main.async { self.loading.remove(index) }
                        continue
                    }
                }

                self?.loadSemaphore.wait()

                // Post-semaphore stale check: may have become stale while waiting
                if let self = self {
                    self.stateLock.lock()
                    let isStale = self.currentGeneration != generation && !self.currentPrefetchRange.contains(index)
                    self.stateLock.unlock()
                    if isStale {
                        self.loadSemaphore.signal()
                        DispatchQueue.main.async { self.loading.remove(index) }
                        continue
                    }
                }

                let cacheKey = diskEnabled ? Self.cacheKey(for: path) : nil
                var texture: MTLTexture?
                var aspect: Float = 1.0
                var rawData: Data?
                var manifestEntry: ManifestEntry?

                // Try disk cache first
                if diskEnabled, let key = cacheKey {
                    if let entry = manifestSnapshot[key] {
                        if let diskPath = self?.diskPath(for: key),
                           let data = try? Data(contentsOf: URL(fileURLWithPath: diskPath)),
                           let tex = ImageLoader.textureFromRawData(data, width: entry.width, height: entry.height, device: device) {
                            texture = tex
                            aspect = entry.aspect
                        }
                    }
                }

                // Generate fresh thumbnail if no cache hit
                if texture == nil {
                    if let result = ImageLoader.generateThumbnail(
                        path: path, device: device, maxPixelSize: maxPixelSize
                    ) {
                        texture = result.texture
                        aspect = result.aspect
                        rawData = result.rawData
                        let mtime = Self.fileModTime(path)
                        manifestEntry = ManifestEntry(width: result.width, height: result.height, aspect: result.aspect, mtime: mtime)
                    }
                }

                self?.loadSemaphore.signal()

                // Deliver this thumbnail immediately to main thread
                if let texture = texture {
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.cache[index] = texture
                        self.aspects[index] = aspect
                        self.loading.remove(index)
                        self.lru.touch(index)

                        // Write to disk cache in background
                        if diskEnabled, let rawData = rawData, let key = cacheKey, let entry = manifestEntry {
                            self.manifest[key] = entry
                            self.manifestDirty = true
                            let diskPath = self.diskPath(for: key)
                            self.manifestQueue.async {
                                self.writeDiskCache(data: rawData, to: diskPath)
                            }
                        }

                        self.evictIfNeeded()
                        if self.manifestDirty {
                            self.saveManifest()
                        }
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
    }

    // MARK: - LRU Eviction

    private func evictIfNeeded() {
        while cache.count > maxCached {
            guard let oldest = lru.evictOldest() else { break }
            cache.removeValue(forKey: oldest)
            aspects.removeValue(forKey: oldest)
        }
    }

    // MARK: - Disk Cache

    private static func cacheKey(for path: String) -> String {
        let mtime = fileModTime(path)
        let input = "\(path):\(mtime)"
        return sha256(input)
    }

    private static func fileModTime(_ path: String) -> Double {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else {
            return 0
        }
        return date.timeIntervalSince1970
    }

    private static func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func diskPath(for key: String) -> String {
        let subdir = (thumbDir as NSString).appendingPathComponent(String(key.prefix(2)))
        ensureDirectory(subdir)
        return (subdir as NSString).appendingPathComponent(key + ".raw")
    }

    private func manifestEntry(for key: String) -> ManifestEntry? {
        return manifest[key]
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

    private func cleanOrphanedFiles(manifestKeys: Set<String>) {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(atPath: thumbDir) else { return }
        for subdir in subdirs {
            let subdirPath = (thumbDir as NSString).appendingPathComponent(subdir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: subdirPath, isDirectory: &isDir), isDir.boolValue,
                  subdir.count == 2 else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: subdirPath) else { continue }
            for file in files {
                guard file.hasSuffix(".raw") else { continue }
                let key = String(file.dropLast(4))  // remove ".raw"
                if !manifestKeys.contains(key) {
                    let filePath = (subdirPath as NSString).appendingPathComponent(file)
                    try? fm.removeItem(atPath: filePath)
                }
            }
        }
    }

    // MARK: - Manifest I/O

    private func loadManifest() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
              let decoded = try? JSONDecoder().decode([String: ManifestEntry].self, from: data) else {
            return
        }
        manifest = decoded
    }

    func flushManifest() {
        guard let work = pendingManifestSave, !work.isCancelled else { return }
        work.cancel()
        pendingManifestSave = nil
        manifestQueue.sync {
            work.perform()
        }
    }

    private func saveManifest() {
        manifestDirty = false
        // Snapshot manifest (value-type copy) on main thread
        let snapshot = manifest
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        pendingManifestSave?.cancel()
        let work = DispatchWorkItem { [manifestPath] in
            try? data.write(to: URL(fileURLWithPath: manifestPath), options: .atomic)
        }
        pendingManifestSave = work
        manifestQueue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}
