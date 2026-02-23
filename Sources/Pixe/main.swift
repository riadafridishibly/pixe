import AppKit

let config = Config.parse()

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

let imageList = ImageList(arguments: config.imageArguments)

if imageList.isEmpty {
    fputs("pixe: no images found\n", stderr)
    exit(1)
}

let initialMode: ViewMode = imageList.count > 1 ? .thumbnail : .image

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate(imageList: imageList, initialMode: initialMode, config: config)
app.delegate = delegate
app.run()
