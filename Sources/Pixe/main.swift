import AppKit

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty {
    fputs("Usage: pixe <image> [image ...]\n", stderr)
    fputs("       pixe <directory>\n", stderr)
    exit(1)
}

let imageList = ImageList(arguments: args)

if imageList.isEmpty {
    fputs("pixe: no images found\n", stderr)
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate(imageList: imageList)
app.delegate = delegate
app.run()
