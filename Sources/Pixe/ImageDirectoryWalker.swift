import Darwin
import Foundation
import UniformTypeIdentifiers

protocol DirectoryImageWalking {
    var name: String { get }
    var isAvailable: Bool { get }
    func walk(at rootPath: String, config: Config, emitBatch: @escaping ([String]) -> Void) -> Bool
}

enum ImageDirectoryWalker {
    private static let strategies: [any DirectoryImageWalking] = [
        FDDirectoryWalker(),
        ReaddirDirectoryWalker(),
        FoundationDirectoryWalker()
    ]

    static func walk(
        at rootPath: String,
        config: Config,
        emitBatch: @escaping ([String]) -> Void
    ) -> String? {
        for strategy in candidateStrategies(for: config.walkStrategy) where strategy.isAvailable {
            if strategy.walk(at: rootPath, config: config, emitBatch: emitBatch) {
                return strategy.name
            }
        }
        return nil
    }

    static func isAvailable(_ strategy: DirectoryWalkStrategy) -> Bool {
        !candidateStrategies(for: strategy).filter { $0.isAvailable }.isEmpty
    }

    private static func candidateStrategies(for configured: DirectoryWalkStrategy) -> [any DirectoryImageWalking] {
        switch configured {
        case .auto:
            return strategies
        case .fd:
            return strategies.filter { $0.name == "fd" }
        case .readdir:
            return strategies.filter { $0.name == "readdir" }
        case .foundation:
            return strategies.filter { $0.name == "foundation" }
        }
    }
}

private struct FDDirectoryWalker: DirectoryImageWalking {
    let name = "fd"
    let isAvailable: Bool
    private let executablePath: String?

    init() {
        if let fd = Self.findExecutable(named: "fd") ?? Self.findExecutable(named: "fdfind") {
            executablePath = fd
            isAvailable = true
        } else {
            executablePath = nil
            isAvailable = false
        }
    }

    func walk(at rootPath: String, config: Config, emitBatch: @escaping ([String]) -> Void) -> Bool {
        guard let executablePath else { return false }
        let allowedExtensions = ExtensionMatcher.allowedExtensions(for: config.extensionFilter)
        if allowedExtensions.isEmpty {
            return true
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.currentDirectoryURL = URL(fileURLWithPath: rootPath)

        var arguments: [String] = [
            "--type", "f",
            "--print0",
            "--absolute-path",
            "--no-ignore",
            "--color", "never"
        ]
        for ext in allowedExtensions.sorted() {
            arguments.append("--extension")
            arguments.append(ext)
        }
        for dir in config.excludedDirNames.sorted() {
            arguments.append("--exclude")
            arguments.append(dir)
        }
        arguments.append(".")
        arguments.append(rootPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }

        let stdout = stdoutPipe.fileHandleForReading
        var partialPathBytes: [UInt8] = []
        partialPathBytes.reserveCapacity(256)
        var batch: [String] = []
        batch.reserveCapacity(1000)
        var emittedAny = false

        func emitCurrentPathIfNeeded() {
            guard !partialPathBytes.isEmpty else { return }
            guard let path = String(bytes: partialPathBytes, encoding: .utf8) else {
                partialPathBytes.removeAll(keepingCapacity: true)
                return
            }
            partialPathBytes.removeAll(keepingCapacity: true)
            guard !path.isEmpty, config.extensionFilter.accepts(path),
                  !config.isPathExcludedByDir(path) else { return }
            batch.append(path)
            if batch.count >= 1000 {
                emitBatch(batch)
                emittedAny = true
                batch.removeAll(keepingCapacity: true)
            }
        }

        while true {
            let chunk = stdout.availableData
            if chunk.isEmpty { break }  // EOF
            for byte in chunk {
                if byte == 0 {
                    emitCurrentPathIfNeeded()
                } else {
                    partialPathBytes.append(byte)
                }
            }
        }
        // Handle output that doesn't end with '\0' (defensive).
        emitCurrentPathIfNeeded()

        process.waitUntilExit()

        // fd commonly exits with 1 when there are no matches.
        guard process.terminationReason == .exit, process.terminationStatus == 0 || process.terminationStatus == 1 else {
            // If partial output was already emitted, treat as handled and avoid fallback duplicates.
            return emittedAny
        }

        if !batch.isEmpty {
            emitBatch(batch)
            emittedAny = true
        }

        return true
    }

    private static func findExecutable(named executable: String) -> String? {
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for segment in envPath.split(separator: ":") {
            let dir = String(segment)
            guard !dir.isEmpty else { continue }
            let candidate = (dir as NSString).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

private struct ReaddirDirectoryWalker: DirectoryImageWalking {
    let name = "readdir"
    let isAvailable = true

    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "appex", "pkg",
        "xcodeproj", "xcworkspace"
    ]

    func walk(at rootPath: String, config: Config, emitBatch: @escaping ([String]) -> Void) -> Bool {
        let allowedExtensions = ExtensionMatcher.allowedExtensions(for: config.extensionFilter)
        if allowedExtensions.isEmpty {
            return true
        }

        var stack: [String] = [rootPath]
        var batch: [String] = []
        batch.reserveCapacity(1000)

        while let dirPath = stack.popLast() {
            guard let dir = opendir(dirPath) else {
                if dirPath == rootPath {
                    return false
                }
                continue
            }

            while let entry = readdir(dir) {
                let name = entryName(entry)
                if name.isEmpty || name == "." || name == ".." || name.hasPrefix(".") {
                    continue
                }

                let fullPath: String
                if dirPath == "/" {
                    fullPath = "/" + name
                } else {
                    fullPath = dirPath + "/" + name
                }

                switch entryType(entry, fullPath: fullPath) {
                case .directory:
                    if shouldSkipPackage(name: name)
                        || config.excludedDirNames.contains(name)
                        || config.excludedDirPaths.contains(fullPath) {
                        continue
                    }
                    stack.append(fullPath)

                case .file:
                    guard ExtensionMatcher.isLikelyImageFile(name: name, allowedExtensions: allowedExtensions),
                          config.extensionFilter.accepts(fullPath)
                    else {
                        continue
                    }
                    batch.append(fullPath)
                    if batch.count >= 1000 {
                        emitBatch(batch)
                        batch.removeAll(keepingCapacity: true)
                    }

                case .other:
                    continue
                }
            }

            closedir(dir)
        }

        if !batch.isEmpty {
            emitBatch(batch)
        }
        return true
    }

    private func shouldSkipPackage(name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot < name.index(before: name.endIndex) else {
            return false
        }
        let ext = name[name.index(after: dot)...].lowercased()
        return Self.packageExtensions.contains(ext)
    }

    private enum EntryKind {
        case file
        case directory
        case other
    }

    private func entryType(_ entry: UnsafeMutablePointer<dirent>, fullPath: String) -> EntryKind {
        let type = entry.pointee.d_type
        switch Int32(type) {
        case DT_REG:
            return .file
        case DT_DIR:
            return .directory
        case DT_UNKNOWN, DT_LNK:
            var st = stat()
            if lstat(fullPath, &st) == 0 {
                let mode = st.st_mode & S_IFMT
                if mode == S_IFDIR { return .directory }
                if mode == S_IFREG { return .file }
            }
            return .other
        default:
            return .other
        }
    }

    private func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: entry.pointee.d_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                String(cString: $0)
            }
        }
    }
}

private struct FoundationDirectoryWalker: DirectoryImageWalking {
    let name = "foundation"
    let isAvailable = true

    func walk(at rootPath: String, config: Config, emitBatch: @escaping ([String]) -> Void) -> Bool {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: rootPath)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey, .isDirectoryKey]

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return false }

        var batch: [String] = []
        batch.reserveCapacity(500)

        for case let fileURL as URL in enumerator {
            if !config.excludedDirNames.isEmpty || !config.excludedDirPaths.isEmpty {
                if let rv = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]),
                   rv.isDirectory == true {
                    let dirName = fileURL.lastPathComponent
                    let dirPath = fileURL.path
                    if config.excludedDirNames.contains(dirName) || config.excludedDirPaths.contains(dirPath) {
                        enumerator.skipDescendants()
                        continue
                    }
                    continue
                }
            }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  let isFile = values.isRegularFile, isFile,
                  let contentType = values.contentType,
                  contentType.conforms(to: .image),
                  config.extensionFilter.accepts(fileURL.path)
            else {
                continue
            }

            batch.append(fileURL.path)
            if batch.count >= 500 {
                emitBatch(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty {
            emitBatch(batch)
        }
        return true
    }
}

private enum ExtensionMatcher {
    // Common formats + RAW formats this app supports.
    private static let defaultImageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "gif", "bmp",
        "tif", "tiff", "webp", "heic", "heif", "avif", "jp2",
        "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2", "dng", "pef", "srw", "x3f"
    ]

    static func allowedExtensions(for filter: ExtensionFilter) -> Set<String> {
        switch filter {
        case let .include(set):
            return set
        case .exclude:
            return Set(defaultImageExtensions.filter { filter.accepts("x.\($0)") })
        }
    }

    static func isLikelyImageFile(name: String, allowedExtensions: Set<String>) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot < name.index(before: name.endIndex) else {
            return false
        }
        let ext = name[name.index(after: dot)...].lowercased()
        return allowedExtensions.contains(ext)
    }
}
