import AppKit

let config = Config.parse()
MemoryProfiler.enabled = config.debugMemory

if !config.quiet {
    if config.configFileLoaded {
        fputs("pixe: config \(Config.configFilePath)\n", stderr)
        for flag in config.configFileFlags {
            fputs("pixe:   \(flag)\n", stderr)
        }
    } else {
        fputs("pixe: config none\n", stderr)
    }
    if !config.cliFlags.isEmpty {
        fputs("pixe: flags \(config.cliFlags.joined(separator: " "))\n", stderr)
    }
}

if config.cleanThumbs {
    Config.cleanThumbsDirectory(config.thumbDir)
    exit(0)
}

if config.warmCache {
    if !config.diskCacheEnabled {
        fputs("pixe: --warm-cache and --no-cache are incompatible\n", stderr)
        exit(1)
    }
    if config.imageArguments.isEmpty {
        fputs("pixe: --warm-cache requires at least one directory argument\n", stderr)
        exit(1)
    }
    CacheWarmer.run(config: config)
    exit(0)
}

var imageArguments = config.imageArguments

if imageArguments.isEmpty {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)

    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Select a folder to open in pixe"
    panel.prompt = "Open"

    let response = panel.runModal()
    guard response == .OK, let url = panel.url else {
        exit(0)
    }
    imageArguments = [url.path]
}

let imageList = ImageList(arguments: imageArguments, config: config)

if imageList.isEmpty && !imageList.hasDirectoryArguments {
    fputs("pixe: no images found\n", stderr)
    exit(1)
}

let initialMode: ViewMode
if imageList.hasDirectoryArguments {
    initialMode = .thumbnail
} else {
    initialMode = imageList.count > 1 ? .thumbnail : .image
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate(imageList: imageList, initialMode: initialMode, config: config)
app.delegate = delegate
app.run()
