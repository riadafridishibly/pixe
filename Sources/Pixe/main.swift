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

if config.imageArguments.isEmpty {
    fputs("Usage: pixe [options] <image> [image ...]\n", stderr)
    fputs("       pixe [options] <directory>\n", stderr)
    fputs("       pixe --clean-thumbs\n", stderr)
    fputs("       pixe --help\n", stderr)
    exit(1)
}

let imageList = ImageList(arguments: config.imageArguments, config: config)

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
