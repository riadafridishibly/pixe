import CoreGraphics
import ImageIO
import Metal

enum GIFLoader {
    static func isGIF(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "gif"
    }

    /// Returns nil for single-frame GIFs (treated as static).
    static func loadAnimatedGIF(from path: String, device: MTLDevice, maxPixelSize: Int) -> GIFAnimator? {
        return autoreleasepool { () -> GIFAnimator? in
            let url = URL(fileURLWithPath: path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

            let count = CGImageSourceGetCount(source)
            guard count > 1 else { return nil }

            var textures: [MTLTexture] = []
            var delays: [TimeInterval] = []
            textures.reserveCapacity(count)
            delays.reserveCapacity(count)

            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]

            for i in 0 ..< count {
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, i, options as CFDictionary),
                      let texture = ImageLoader.createSharedTexture(from: cgImage, device: device)
                else { continue }

                textures.append(texture)
                delays.append(frameDelay(source: source, index: i))
            }

            return GIFAnimator(textures: textures, delays: delays)
        }
    }

    private static func frameDelay(source: CGImageSource, index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifDict = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }

        // Prefer unclamped delay, fall back to standard delay
        if let unclamped = gifDict[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0 {
            return unclamped
        }
        if let delay = gifDict[kCGImagePropertyGIFDelayTime] as? Double, delay > 0 {
            return delay
        }
        return 0.1
    }
}
