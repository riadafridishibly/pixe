import Foundation

struct Config {
    let thumbDir: String
    let thumbSize: Int
    let diskCacheEnabled: Bool
    let cleanThumbs: Bool
    let imageArguments: [String]

    static let defaultThumbDir: String = {
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".cache/pixe/thumbs")
    }()

    static let defaultThumbSize: Int = 256

    static func parse(_ args: [String] = Array(CommandLine.arguments.dropFirst())) -> Config {
        var thumbDir = defaultThumbDir
        var thumbSize = defaultThumbSize
        var diskCacheEnabled = true
        var cleanThumbs = false
        var imageArguments: [String] = []

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
            case "--no-cache":
                diskCacheEnabled = false
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                imageArguments.append(arg)
            }
            i += 1
        }

        return Config(
            thumbDir: thumbDir,
            thumbSize: thumbSize,
            diskCacheEnabled: diskCacheEnabled,
            cleanThumbs: cleanThumbs,
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

    private static func printUsage() {
        let usage = """
        Usage: pixe [options] <image|directory> [image|directory ...]

        Options:
          --thumb-dir <path>   Thumbnail cache directory (default: ~/.cache/pixe/thumbs)
          --thumb-size <int>   Max thumbnail pixel size (default: 256)
          --no-cache           Disable disk thumbnail cache
          --clean-thumbs       Delete thumbnail cache and exit
          -h, --help           Show this help
        """
        fputs(usage + "\n", stderr)
    }
}
