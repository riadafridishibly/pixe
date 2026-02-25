import Foundation

enum CacheWarmer {
    static func run(config: Config) {
        let startTime = DispatchTime.now()
        let thumbDir = config.thumbDir
        let maxPixelSize = config.thumbSize
        let fm = FileManager.default
        if !fm.fileExists(atPath: thumbDir) {
            try? fm.createDirectory(atPath: thumbDir, withIntermediateDirectories: true)
        }

        guard let metadataStore = MetadataStore(directory: thumbDir) else {
            fputs("pixe: warm-cache: failed to open metadata store\n", stderr)
            return
        }

        // Discover all files
        var allFiles: [String] = []
        var filesByDirectory: [String: [String]] = [:]

        for arg in config.imageArguments {
            var path: String
            if arg.hasPrefix("/") || arg.hasPrefix("~") {
                path = (arg as NSString).expandingTildeInPath
            } else {
                path = (fm.currentDirectoryPath as NSString).appendingPathComponent(arg)
            }
            path = URL(fileURLWithPath: path).standardized.path

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
                fputs("pixe: warm-cache: \(arg): No such file or directory\n", stderr)
                continue
            }

            if isDir.boolValue {
                var dirFiles: [String] = []
                _ = ImageDirectoryWalker.walk(at: path, config: config) { batch in
                    dirFiles.append(contentsOf: batch)
                }

                // Store all entries under the top-level argument directory.
                // Child directory queries use prefix matching on the path column,
                // so they'll find these entries without duplication.
                filesByDirectory[path, default: []].append(contentsOf: dirFiles)

                allFiles.append(contentsOf: dirFiles)
            } else {
                if ImageLoader.isImageFile(path) && config.extensionFilter.accepts(path) {
                    allFiles.append(path)
                }
            }
        }

        // Deduplicate: overlapping directory arguments can produce duplicate entries
        var seen = Set<String>()
        allFiles = allFiles.filter { seen.insert($0).inserted }

        // Persist directory entries
        for (dirPath, paths) in filesByDirectory {
            metadataStore.replaceDirectoryEntries(dirPath: dirPath, paths: paths)
        }

        let totalCount = allFiles.count
        if totalCount == 0 {
            fputs("pixe: warm-cache: no images found\n", stderr)
            return
        }

        let isTTY = isatty(STDERR_FILENO) != 0

        // Thread-safe progress tracking
        let progress = WarmCacheProgress(total: totalCount, isTTY: isTTY)

        // Process files concurrently
        let semaphore = DispatchSemaphore(value: 8)
        let group = DispatchGroup()

        for file in allFiles {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                semaphore.wait()
                processFile(
                    path: file,
                    thumbDir: thumbDir,
                    maxPixelSize: maxPixelSize,
                    metadataStore: metadataStore,
                    progress: progress
                )
                semaphore.signal()
                group.leave()
            }
        }

        group.wait()

        metadataStore.flush()

        // Clear the progress line before printing the final summary
        if isTTY {
            fputs("\r\u{1B}[K", stderr)
        }

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000
        let stats = progress.snapshot()
        fputs(
            String(
                format: "pixe: warm-cache: done in %.1fs — %d processed, %d generated, %d cached, %d failed\n",
                elapsed, stats.processed, stats.generated, stats.cached, stats.failed
            ),
            stderr
        )
    }

    private static func processFile(
        path: String,
        thumbDir: String,
        maxPixelSize: Int,
        metadataStore: MetadataStore,
        progress: WarmCacheProgress
    ) {
        var didGenerate = false
        var didFail = false

        // Read file attributes once for the entire function
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            progress.recordFailed(path: path)
            return
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        // 1. Thumbnail
        let cacheKey = ThumbnailCache.cacheKey(for: path, mtime: mtime)
        let diskPath = ThumbnailCache.diskPath(for: cacheKey, thumbDir: thumbDir)

        let hasThumbMeta = metadataStore.thumbnail(forKey: cacheKey) != nil
        let hasThumbFile = FileManager.default.fileExists(atPath: diskPath)

        if !hasThumbMeta || !hasThumbFile {
            if let result = ImageLoader.generateThumbnailData(path: path, maxPixelSize: maxPixelSize) {
                // Ensure subdirectory exists
                let subdir = (diskPath as NSString).deletingLastPathComponent
                if !FileManager.default.fileExists(atPath: subdir) {
                    try? FileManager.default.createDirectory(atPath: subdir, withIntermediateDirectories: true)
                }
                do {
                    try result.cacheData.write(to: URL(fileURLWithPath: diskPath), options: .atomic)
                    metadataStore.upsertThumbnail(
                        key: cacheKey,
                        sourcePath: path,
                        sourceMtime: mtime,
                        width: result.width,
                        height: result.height,
                        aspect: result.aspect
                    )
                    didGenerate = true
                } catch {
                    didFail = true
                }
            } else {
                didFail = true
            }
        }

        // 2. EXIF
        if metadataStore.cachedExif(path: path, mtime: mtime, fileSize: fileSize) == nil {
            let captureDate = ImageList.readExifCaptureDate(for: path)
            metadataStore.upsertExif(path: path, mtime: mtime, fileSize: fileSize, captureDate: captureDate)
        }

        // 3. Dimensions
        if metadataStore.cachedDimensions(path: path) == nil {
            if let dims = ImageLoader.imageDimensions(path: path) {
                metadataStore.upsertDimensions(path: path, width: dims.width, height: dims.height)
            }
        }

        if didFail {
            progress.recordFailed(path: path)
        } else if didGenerate {
            progress.recordGenerated(path: path)
        } else {
            progress.recordCached(path: path)
        }
    }
}

private class WarmCacheProgress {
    struct Snapshot {
        let processed: Int
        let generated: Int
        let cached: Int
        let failed: Int
    }

    private let total: Int
    private let isTTY: Bool
    private var generated: Int = 0
    private var cached: Int = 0
    private var failed: Int = 0
    private let lock = NSLock()
    private let printLock = NSLock()
    private let startTime = DispatchTime.now()

    init(total: Int, isTTY: Bool) {
        self.total = total
        self.isTTY = isTTY
    }

    func recordGenerated(path: String) {
        lock.lock()
        generated += 1
        let s = lockedSnapshot()
        lock.unlock()
        printLock.lock()
        printUpdate(s, path: path)
        printLock.unlock()
    }

    func recordCached(path: String) {
        lock.lock()
        cached += 1
        let s = lockedSnapshot()
        lock.unlock()
        printLock.lock()
        printUpdate(s, path: path)
        printLock.unlock()
    }

    func recordFailed(path: String) {
        lock.lock()
        failed += 1
        let s = lockedSnapshot()
        lock.unlock()
        printLock.lock()
        printUpdate(s, path: path)
        printLock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let s = lockedSnapshot()
        lock.unlock()
        return s
    }

    private func lockedSnapshot() -> Snapshot {
        Snapshot(processed: generated + cached + failed, generated: generated, cached: cached, failed: failed)
    }

    private func printUpdate(_ s: Snapshot, path: String) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000
        let rate = elapsed > 0 ? Int(Double(s.processed) / elapsed) : 0
        let filename = (path as NSString).lastPathComponent

        if isTTY {
            // Overwrite the current line, truncating to terminal width
            let prefix = String(
                format: "pixe: warm-cache: %d/%d (%d/s) ",
                s.processed, total, rate
            )
            var cols = 80
            var ws = winsize()
            if ioctl(STDERR_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
                cols = Int(ws.ws_col)
            }
            let maxName = cols - prefix.count
            let truncatedName: String
            if maxName >= filename.count {
                truncatedName = filename
            } else if maxName > 1 {
                truncatedName = "\u{2026}" + filename.suffix(maxName - 1)
            } else {
                truncatedName = ""
            }
            fputs("\r\u{1B}[K\(prefix)\(truncatedName)", stderr)
        } else {
            // Non-TTY: print a line every 100 files or on the last file
            if s.processed == total || s.processed % 100 == 0 {
                fputs(
                    String(
                        format: "pixe: warm-cache: %d/%d (%d/s) — %d generated, %d cached, %d failed\n",
                        s.processed, total, rate, s.generated, s.cached, s.failed
                    ),
                    stderr
                )
            }
        }
    }
}
