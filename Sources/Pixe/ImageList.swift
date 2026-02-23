import Foundation
import UniformTypeIdentifiers

class ImageList {
    private var paths: [String] = []
    private(set) var currentIndex: Int = 0

    var count: Int { paths.count }
    var isEmpty: Bool { paths.isEmpty }
    var allPaths: [String] { paths }

    var currentPath: String? {
        guard !paths.isEmpty else { return nil }
        return paths[currentIndex]
    }

    init(arguments: [String], config: Config) {
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
                enumerateDirectory(at: path, fileManager: fileManager, config: config)
            } else {
                if ImageLoader.isImageFile(path) && config.extensionFilter.accepts(path) {
                    paths.append(path)
                }
            }
        }
    }

    private func enumerateDirectory(at path: String, fileManager: FileManager, config: Config) {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        var discovered: [String] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  let isFile = values.isRegularFile, isFile,
                  let contentType = values.contentType,
                  contentType.conforms(to: .image) else {
                continue
            }
            guard config.extensionFilter.accepts(fileURL.path) else { continue }
            discovered.append(fileURL.path)
        }
        discovered.sort()
        paths.append(contentsOf: discovered)
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

    func goTo(index: Int) {
        guard !paths.isEmpty else { return }
        currentIndex = max(0, min(index, paths.count - 1))
    }
}
