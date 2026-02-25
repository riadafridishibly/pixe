import Foundation

enum ExtensionFilter {
    case exclude(Set<String>)
    case include(Set<String>)

    static let defaultExcluded: Set<String> = ["svg", "pdf"]

    func accepts(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        switch self {
        case let .exclude(set): return !set.contains(ext)
        case let .include(set): return set.contains(ext)
        }
    }
}

enum DirectoryWalkStrategy: String {
    case auto
    case fd
    case readdir
    case foundation
}

enum SortMode: String {
    case name
    case chrono
    case reverseChrono = "reverse-chrono"

    var requiresExplicitSort: Bool {
        self != .name
    }
}

struct Config {
    let thumbDir: String
    let thumbSize: Int
    let minSize: Int
    let minWidth: Int
    let minHeight: Int
    let maxWidth: Int
    let maxHeight: Int
    let diskCacheEnabled: Bool
    let cleanThumbs: Bool
    let debugMemory: Bool
    let walkStrategy: DirectoryWalkStrategy
    let sortMode: SortMode
    let extensionFilter: ExtensionFilter
    let excludedDirNames: Set<String>
    let excludedDirPaths: Set<String>
    let warmCache: Bool
    let quiet: Bool
    let configFileLoaded: Bool
    let configFileFlags: [String]
    let cliFlags: [String]
    let imageArguments: [String]

    static let defaultThumbDir: String = {
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".cache/pixe/thumbs")
    }()

    static let defaultThumbSize: Int = 256

    static let configFilePath: String = {
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".config/pixe/config")
    }()

    private static func loadConfigFileArgs() -> (args: [String], loaded: Bool) {
        let path = configFilePath
        guard FileManager.default.fileExists(atPath: path) else {
            return ([], false)
        }
        let contents: String
        do {
            contents = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            fputs("pixe: failed to read config file \(path): \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        var args: [String] = []
        for (lineNumber, line) in contents.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard trimmed.hasPrefix("-") else {
                fputs("pixe: \(path):\(lineNumber + 1): expected flag, got '\(trimmed)'\n", stderr)
                exit(1)
            }
            // --flag=value → single arg (strip surrounding quotes from value)
            // --flag value → two args (strip surrounding quotes from value)
            // --flag       → single arg
            if let eqIdx = trimmed.firstIndex(of: "=") {
                let flag = String(trimmed[trimmed.startIndex...eqIdx])
                let rawValue = String(trimmed[trimmed.index(after: eqIdx)...])
                args.append(flag + stripQuotes(rawValue))
            } else if let spIdx = trimmed.firstIndex(of: " ") {
                let flag = String(trimmed[trimmed.startIndex..<spIdx])
                let rawValue = String(trimmed[trimmed.index(after: spIdx)...])
                    .trimmingCharacters(in: .whitespaces)
                args.append(flag)
                args.append(stripQuotes(rawValue))
            } else {
                args.append(trimmed)
            }
        }
        return (args, true)
    }

    static func parse(_ args: [String] = Array(CommandLine.arguments.dropFirst())) -> Config {
        let (configFileArgs, configFileLoaded) = loadConfigFileArgs()
        let allArgs = configFileArgs + args

        var thumbDir = defaultThumbDir
        var thumbSize = defaultThumbSize
        var minSize = 0
        var minWidth = 0
        var minHeight = 0
        var maxWidth = 0
        var maxHeight = 0
        var diskCacheEnabled = true
        var cleanThumbs = false
        var warmCache = false
        var debugMemory = false
        var quiet = false
        var walkStrategy: DirectoryWalkStrategy = .auto
        var sortMode: SortMode = .name
        var imageArguments: [String] = []
        var includeExts: Set<String>?
        var excludeExts: Set<String>?
        var excludedDirNames: Set<String> = []
        var excludedDirPaths: Set<String> = []

        var i = 0
        while i < allArgs.count {
            let arg = allArgs[i]
            switch arg {
            case "--quiet":
                quiet = true
            case "--clean-thumbs":
                cleanThumbs = true
            case "--warm-cache":
                warmCache = true
            case "--thumb-dir":
                i += 1
                if i < allArgs.count {
                    let path = allArgs[i]
                    if path.hasPrefix("/") || path.hasPrefix("~") {
                        thumbDir = (path as NSString).expandingTildeInPath
                    } else {
                        thumbDir = (FileManager.default.currentDirectoryPath as NSString)
                            .appendingPathComponent(path)
                    }
                }
            case "--thumb-size":
                i += 1
                if i < allArgs.count, let size = Int(allArgs[i]), size > 0 {
                    thumbSize = size
                }
            case let a where a.hasPrefix("--min-size="):
                if let size = Int(String(a.dropFirst("--min-size=".count))), size >= 0 {
                    minSize = size
                }
            case "--min-size":
                i += 1
                if i < allArgs.count, let size = Int(allArgs[i]), size >= 0 {
                    minSize = size
                }
            case let a where a.hasPrefix("--min-width="):
                if let v = Int(String(a.dropFirst("--min-width=".count))), v >= 0 { minWidth = v }
            case "--min-width":
                i += 1
                if i < allArgs.count, let v = Int(allArgs[i]), v >= 0 { minWidth = v }
            case let a where a.hasPrefix("--min-height="):
                if let v = Int(String(a.dropFirst("--min-height=".count))), v >= 0 { minHeight = v }
            case "--min-height":
                i += 1
                if i < allArgs.count, let v = Int(allArgs[i]), v >= 0 { minHeight = v }
            case let a where a.hasPrefix("--max-width="):
                if let v = Int(String(a.dropFirst("--max-width=".count))), v > 0 { maxWidth = v }
            case "--max-width":
                i += 1
                if i < allArgs.count, let v = Int(allArgs[i]), v > 0 { maxWidth = v }
            case let a where a.hasPrefix("--max-height="):
                if let v = Int(String(a.dropFirst("--max-height=".count))), v > 0 { maxHeight = v }
            case "--max-height":
                i += 1
                if i < allArgs.count, let v = Int(allArgs[i]), v > 0 { maxHeight = v }
            case "--no-cache":
                diskCacheEnabled = false
            case "--debug-mem":
                debugMemory = true
            case let a where a.hasPrefix("--walker="):
                let value = String(a.dropFirst("--walker=".count)).lowercased()
                guard let parsed = DirectoryWalkStrategy(rawValue: value) else {
                    fputs("pixe: invalid --walker value '\(value)' (expected: auto|fd|readdir|foundation)\n", stderr)
                    exit(1)
                }
                walkStrategy = parsed
            case "--walker":
                i += 1
                guard i < allArgs.count else {
                    fputs("pixe: --walker requires a value (auto|fd|readdir|foundation)\n", stderr)
                    exit(1)
                }
                let value = allArgs[i].lowercased()
                guard let parsed = DirectoryWalkStrategy(rawValue: value) else {
                    fputs("pixe: invalid --walker value '\(value)' (expected: auto|fd|readdir|foundation)\n", stderr)
                    exit(1)
                }
                walkStrategy = parsed
            case let a where a.hasPrefix("--sort="):
                let value = String(a.dropFirst("--sort=".count)).lowercased()
                guard let parsed = SortMode(rawValue: value) else {
                    fputs("pixe: invalid --sort value '\(value)' (expected: name|chrono|reverse-chrono)\n", stderr)
                    exit(1)
                }
                sortMode = parsed
            case "--sort":
                i += 1
                guard i < allArgs.count else {
                    fputs("pixe: --sort requires a value (name|chrono|reverse-chrono)\n", stderr)
                    exit(1)
                }
                let value = allArgs[i].lowercased()
                guard let parsed = SortMode(rawValue: value) else {
                    fputs("pixe: invalid --sort value '\(value)' (expected: name|chrono|reverse-chrono)\n", stderr)
                    exit(1)
                }
                sortMode = parsed
            case "--chrono":
                sortMode = .chrono
            case "--reverse-chrono":
                sortMode = .reverseChrono
            case let a where a.hasPrefix("--include="):
                if excludeExts != nil {
                    fputs("pixe: --include overrides previous --exclude\n", stderr)
                    excludeExts = nil
                }
                includeExts = parseExtensions(String(a.dropFirst("--include=".count)))
            case "--include":
                i += 1
                if i < allArgs.count {
                    if excludeExts != nil {
                        fputs("pixe: --include overrides previous --exclude\n", stderr)
                        excludeExts = nil
                    }
                    includeExts = parseExtensions(allArgs[i])
                }
            case let a where a.hasPrefix("--exclude="):
                if includeExts != nil {
                    fputs("pixe: --exclude overrides previous --include\n", stderr)
                    includeExts = nil
                }
                excludeExts = parseExtensions(String(a.dropFirst("--exclude=".count)))
            case "--exclude":
                i += 1
                if i < allArgs.count {
                    if includeExts != nil {
                        fputs("pixe: --exclude overrides previous --include\n", stderr)
                        includeExts = nil
                    }
                    excludeExts = parseExtensions(allArgs[i])
                }
            case let a where a.hasPrefix("--exclude-dir="):
                let value = String(a.dropFirst("--exclude-dir=".count))
                parseDirExclusions(value, names: &excludedDirNames, paths: &excludedDirPaths)
            case "--exclude-dir":
                i += 1
                if i < allArgs.count {
                    parseDirExclusions(allArgs[i], names: &excludedDirNames, paths: &excludedDirPaths)
                }
            case "--version", "-v":
                printVersion()
                exit(0)
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                imageArguments.append(arg)
            }
            i += 1
        }

        let extensionFilter: ExtensionFilter
        if let incl = includeExts {
            extensionFilter = .include(incl)
        } else {
            extensionFilter = .exclude(ExtensionFilter.defaultExcluded.union(excludeExts ?? []))
        }

        return Config(
            thumbDir: thumbDir,
            thumbSize: thumbSize,
            minSize: minSize,
            minWidth: minWidth,
            minHeight: minHeight,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            diskCacheEnabled: diskCacheEnabled,
            cleanThumbs: cleanThumbs,
            debugMemory: debugMemory,
            walkStrategy: walkStrategy,
            sortMode: sortMode,
            extensionFilter: extensionFilter,
            excludedDirNames: excludedDirNames,
            excludedDirPaths: excludedDirPaths,
            warmCache: warmCache,
            quiet: quiet,
            configFileLoaded: configFileLoaded,
            configFileFlags: configFileArgs,
            cliFlags: args.filter { $0.hasPrefix("-") },
            imageArguments: imageArguments
        )
    }

    private static func stripQuotes(_ s: String) -> String {
        if s.count >= 2,
           (s.first == "\"" && s.last == "\"") || (s.first == "'" && s.last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    static func cleanThumbsDirectory(_ dir: String) {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir) {
            do {
                try fm.removeItem(atPath: dir)
                fputs("pixe: cleaned thumbnail cache at \(dir)\n", stderr)
            } catch {
                fputs("pixe: failed to clean thumbnail cache: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        } else {
            fputs("pixe: no thumbnail cache found at \(dir)\n", stderr)
        }
    }

    private static func parseExtensions(_ value: String) -> Set<String> {
        Set(value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : String($0) }
            .map { $0.lowercased() }
            .filter { !$0.isEmpty })
    }

    private static func parseDirExclusions(_ value: String, names: inout Set<String>, paths: inout Set<String>) {
        for item in value.split(separator: ",") {
            let trimmed = item.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.contains("/") || trimmed.hasPrefix("~") {
                let expanded = (trimmed as NSString).expandingTildeInPath
                let normalized = expanded.hasSuffix("/") && expanded != "/"
                    ? String(expanded.dropLast()) : expanded
                paths.insert(normalized)
            } else {
                names.insert(trimmed)
            }
        }
    }

    func isPathExcludedByDir(_ path: String) -> Bool {
        if !excludedDirNames.isEmpty {
            let components = (path as NSString).pathComponents
            if components.contains(where: { excludedDirNames.contains($0) }) {
                return true
            }
        }
        if !excludedDirPaths.isEmpty {
            for excluded in excludedDirPaths {
                let prefix = excluded.hasSuffix("/") ? excluded : excluded + "/"
                if path.hasPrefix(prefix) {
                    return true
                }
            }
        }
        return false
    }

    private static func printVersion() {
        fputs("pixe \(BuildInfo.version) (\(BuildInfo.commit))\n", stderr)
    }

    private static func printUsage() {
        let usage = """
        Usage: pixe [options] <image|directory> [image|directory ...]

        Options:
          --thumb-dir <path>   Thumbnail cache directory (default: ~/.cache/pixe/thumbs)
          --thumb-size <int>   Max thumbnail pixel size (default: 256)
          --min-size <pixels>  Skip images smaller than <pixels> on longest side
          --min-width <px>     Skip images narrower than <px>
          --min-height <px>    Skip images shorter than <px>
          --max-width <px>     Skip images wider than <px>
          --max-height <px>    Skip images taller than <px>
          --no-cache           Disable disk thumbnail cache
          --walker <strategy>  Traversal strategy: auto|fd|readdir|foundation (default: auto)
          --sort <mode>        Sort mode: name|chrono|reverse-chrono (default: name)
          --chrono             Shortcut for --sort chrono
          --reverse-chrono     Shortcut for --sort reverse-chrono
          --include <exts>     Only show these extensions (e.g. --include=.jpg,.png)
          --exclude <exts>     Hide these extensions (e.g. --exclude=.svg,.pdf)
          --exclude-dir <dirs> Skip directories by name or path (e.g. node_modules,~/Photos/Trash)
          --quiet              Suppress startup config message
          --clean-thumbs       Delete thumbnail cache and exit
          --warm-cache         Pre-populate thumbnail/metadata cache headlessly and exit
          --debug-mem          Enable [mem] event logging to stderr
          -v, --version        Show version
          -h, --help           Show this help

        By default, .svg and .pdf are excluded. --include and --exclude are mutually exclusive.
        """
        fputs(usage + "\n", stderr)
    }
}
