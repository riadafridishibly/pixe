import Metal
import MetalKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum ImageLoader {
    static func loadTexture(from path: String, device: MTLDevice) -> MTLTexture? {
        let url = URL(fileURLWithPath: path)

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        // Get image dimensions without full decode
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            // Fallback: try loading without dimension check
            return loadDirectly(imageSource: imageSource, device: device)
        }

        let maxDim = 16384 // Apple Silicon max texture dimension

        let cgImage: CGImage?
        if width > maxDim || height > maxDim {
            // Downsample oversized images at the codec level
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxDim,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
        } else {
            let options: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: true
            ]
            cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary)
        }

        guard let image = cgImage else { return nil }
        return createTexture(from: image, device: device)
    }

    private static func loadDirectly(imageSource: CGImageSource, device: MTLDevice) -> MTLTexture? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }
        return createTexture(from: image, device: device)
    }

    private static func createTexture(from cgImage: CGImage, device: MTLDevice) -> MTLTexture? {
        let textureLoader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .origin: MTKTextureLoader.Origin.topLeft,
            .SRGB: true
        ]
        return try? textureLoader.newTexture(cgImage: cgImage, options: options)
    }

    static func isImageFile(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey]),
              let contentType = resourceValues.contentType else {
            return false
        }
        return contentType.conforms(to: .image)
    }
}
