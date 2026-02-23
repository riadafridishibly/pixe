import Foundation

class ImageList {
    private var paths: [String] = []
    private(set) var currentIndex: Int = 0

    var count: Int { paths.count }
    var isEmpty: Bool { paths.isEmpty }

    var currentPath: String? {
        guard !paths.isEmpty else { return nil }
        return paths[currentIndex]
    }

    init(arguments: [String]) {
        let fileManager = FileManager.default

        for arg in arguments {
            let path: String
            if arg.hasPrefix("/") || arg.hasPrefix("~") {
                path = (arg as NSString).expandingTildeInPath
            } else {
                path = (fileManager.currentDirectoryPath as NSString).appendingPathComponent(arg)
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                fputs("pixe: \(arg): No such file or directory\n", stderr)
                continue
            }

            if isDirectory.boolValue {
                if let contents = try? fileManager.contentsOfDirectory(atPath: path) {
                    for file in contents.sorted() {
                        let fullPath = (path as NSString).appendingPathComponent(file)
                        if ImageLoader.isImageFile(fullPath) {
                            paths.append(fullPath)
                        }
                    }
                }
            } else {
                if ImageLoader.isImageFile(path) {
                    paths.append(path)
                }
            }
        }
    }

    func goNext() {
        guard !paths.isEmpty else { return }
        currentIndex = (currentIndex + 1) % paths.count
    }

    func goPrevious() {
        guard !paths.isEmpty else { return }
        currentIndex = (currentIndex - 1 + paths.count) % paths.count
    }

    func goFirst() {
        currentIndex = 0
    }

    func goLast() {
        guard !paths.isEmpty else { return }
        currentIndex = paths.count - 1
    }
}
