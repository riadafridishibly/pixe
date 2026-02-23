import Metal
import ImageIO
import CoreGraphics

class ThumbnailCache {
    let device: MTLDevice
    let maxCached: Int = 300
    let maxPixelSize: Int = 256

    private var cache: [Int: MTLTexture] = [:]
    private(set) var aspects: [Int: Float] = [:]
    private var loading: Set<Int> = []
    private var accessOrder: [Int] = []

    private let loadQueue = DispatchQueue(label: "pixe.thumbnail", qos: .utility, attributes: .concurrent)

    init(device: MTLDevice) {
        self.device = device
    }

    func texture(at index: Int) -> MTLTexture? {
        if let tex = cache[index] {
            touchAccess(index)
            return tex
        }
        return nil
    }

    func aspect(at index: Int) -> Float {
        return aspects[index] ?? 1.0
    }

    func ensureLoaded(indices: Range<Int>, paths: [String], completion: @escaping () -> Void) {
        var toLoad: [(Int, String)] = []
        for i in indices {
            guard i < paths.count else { continue }
            if cache[i] != nil || loading.contains(i) { continue }
            loading.insert(i)
            toLoad.append((i, paths[i]))
        }

        guard !toLoad.isEmpty else { return }

        let device = self.device
        let maxPixelSize = self.maxPixelSize

        loadQueue.async { [weak self] in
            var results: [(Int, MTLTexture, Float)] = []

            for (index, path) in toLoad {
                guard let (texture, aspect) = Self.generateThumbnail(
                    path: path, device: device, maxPixelSize: maxPixelSize
                ) else { continue }
                results.append((index, texture, aspect))
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                for (index, texture, aspect) in results {
                    self.cache[index] = texture
                    self.aspects[index] = aspect
                    self.loading.remove(index)
                    self.touchAccess(index)
                }
                self.evictIfNeeded()
                completion()
            }
        }
    }

    private static func generateThumbnail(
        path: String, device: MTLDevice, maxPixelSize: Int
    ) -> (MTLTexture, Float)? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let aspect = Float(cgImage.width) / Float(cgImage.height)

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              ),
              let data = context.data else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(
            region: MTLRegion(origin: .init(), size: MTLSize(width: width, height: height, depth: 1)),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )

        return (texture, aspect)
    }

    private func touchAccess(_ index: Int) {
        if let pos = accessOrder.firstIndex(of: index) {
            accessOrder.remove(at: pos)
        }
        accessOrder.append(index)
    }

    private func evictIfNeeded() {
        while cache.count > maxCached && !accessOrder.isEmpty {
            let oldest = accessOrder.removeFirst()
            cache.removeValue(forKey: oldest)
            aspects.removeValue(forKey: oldest)
        }
    }

    func invalidateAll() {
        cache.removeAll()
        aspects.removeAll()
        accessOrder.removeAll()
        loading.removeAll()
    }
}
