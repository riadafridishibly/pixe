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
    let diskCacheEnabled: Bool
    let cleanThumbs: Bool
    let debugMemory: Bool
    let walkStrategy: DirectoryWalkStrategy
    let sortMode: SortMode
    let extensionFilter: ExtensionFilter
    let imageArguments: [String]

    static let defaultThumbDir: String = {
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".cache/pixe/thumbs")
    }()

    static let defaultThumbSize: Int = 256

    static func parse(_ args: [String] = Array(CommandLine.arguments.dropFirst())) -> Config {
        var thumbDir = defaultThumbDir
        var thumbSize = defaultThumbSize
        var minSize = 0
        var diskCacheEnabled = true
        var cleanThumbs = false
        var debugMemory = false
        var walkStrategy: DirectoryWalkStrategy = .auto
        var sortMode: SortMode = .name
        var imageArguments: [String] = []
        var includeExts: Set<String>?
        var excludeExts: Set<String>?

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--clean-thumbs":
                cleanThumbs = true
            case "--thumb-dir":
                i += 1
                if i < args.count {
                    let path = args[i]
                    if path.hasPrefix("/") || path.hasPrefix("~") {
                        thumbDir = (path as NSString).expandingTildeInPath
                    } else {
                        thumbDir = (FileManager.default.currentDirectoryPath as NSString)
                            .appendingPathComponent(path)
                    }
                }
            case "--thumb-size":
                i += 1
                if i < args.count, let size = Int(args[i]), size > 0 {
                    thumbSize = size
                }
            case let a where a.hasPrefix("--min-size="):
                if let size = Int(String(a.dropFirst("--min-size=".count))), size >= 0 {
                    minSize = size
                }
            case "--min-size":
                i += 1
                if i < args.count, let size = Int(args[i]), size >= 0 {
                    minSize = size
                }
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
                guard i < args.count else {
                    fputs("pixe: --walker requires a value (auto|fd|readdir|foundation)\n", stderr)
                    exit(1)
                }
                let value = args[i].lowercased()
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
                guard i < args.count else {
                    fputs("pixe: --sort requires a value (name|chrono|reverse-chrono)\n", stderr)
                    exit(1)
                }
                let value = args[i].lowercased()
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
                includeExts = parseExtensions(String(a.dropFirst("--include=".count)))
            case "--include":
                i += 1
                if i < args.count { includeExts = parseExtensions(args[i]) }
            case let a where a.hasPrefix("--exclude="):
                excludeExts = parseExtensions(String(a.dropFirst("--exclude=".count)))
            case "--exclude":
                i += 1
                if i < args.count { excludeExts = parseExtensions(args[i]) }
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

        if includeExts != nil && excludeExts != nil {
            fputs("pixe: --include and --exclude are mutually exclusive\n", stderr)
            exit(1)
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
            diskCacheEnabled: diskCacheEnabled,
            cleanThumbs: cleanThumbs,
            debugMemory: debugMemory,
            walkStrategy: walkStrategy,
            sortMode: sortMode,
            extensionFilter: extensionFilter,
            imageArguments: imageArguments
        )
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

    private static func printVersion() {
        fputs("pixe \(BuildInfo.version) (\(BuildInfo.commit))\n", stderr)
    }

    private static func printUsage() {
        let usage = """
        Usage: pixe [options] <image|directory> [image|directory ...]

        Options:
          --thumb-dir <path>   Thumbnail cache directory (default: ~/.cache/pixe/thumbs)
          --thumb-size <int>   Max thumbnail pixel size (default: 256)
          --min-size <pixels>  Skip images smaller than <pixels> on longest side (default: 0)
          --no-cache           Disable disk thumbnail cache
          --walker <strategy>  Traversal strategy: auto|fd|readdir|foundation (default: auto)
          --sort <mode>        Sort mode: name|chrono|reverse-chrono (default: name)
          --chrono             Shortcut for --sort chrono
          --reverse-chrono     Shortcut for --sort reverse-chrono
          --include <exts>     Only show these extensions (e.g. --include=.jpg,.png)
          --exclude <exts>     Hide these extensions (e.g. --exclude=.svg,.pdf)
          --clean-thumbs       Delete thumbnail cache and exit
          --debug-mem          Enable [mem] event logging to stderr
          -v, --version        Show version
          -h, --help           Show this help

        By default, .svg and .pdf are excluded. --include and --exclude are mutually exclusive.
        """
        fputs(usage + "\n", stderr)
    }
}
