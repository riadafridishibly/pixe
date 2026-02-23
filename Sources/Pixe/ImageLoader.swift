import Metal
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum ImageLoader {

    // MARK: - Full Image Loading

    static func loadTexture(from path: String, device: MTLDevice, commandQueue: MTLCommandQueue) -> MTLTexture? {
        let url = URL(fileURLWithPath: path)

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return loadDirectly(imageSource: imageSource, device: device, commandQueue: commandQueue)
        }

        let maxDim = 16384

        let cgImage: CGImage?
        if width > maxDim || height > maxDim {
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
        return createTexture(from: image, device: device, commandQueue: commandQueue, mipmapped: true)
    }

    private static func loadDirectly(imageSource: CGImageSource, device: MTLDevice, commandQueue: MTLCommandQueue) -> MTLTexture? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }
        return createTexture(from: image, device: device, commandQueue: commandQueue, mipmapped: true)
    }

    // MARK: - Thumbnail Generation (shared by ThumbnailCache)

    struct ThumbnailResult {
        let texture: MTLTexture
        let rawData: Data
        let width: Int
        let height: Int
        let aspect: Float
    }

    static func generateThumbnail(
        path: String, device: MTLDevice, maxPixelSize: Int
    ) -> ThumbnailResult? {
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
        let dataSize = bytesPerRow * height

        // Decode directly into a Metal shared buffer — no intermediate CGContext malloc
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let buffer = device.makeBuffer(length: dataSize, options: .storageModeShared)
        guard let buffer = buffer else { return nil }

        guard let context = CGContext(
            data: buffer.contents(),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Create texture from buffer data
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
            withBytes: buffer.contents(),
            bytesPerRow: bytesPerRow
        )

        // Copy raw data for disk cache
        let rawData = Data(bytes: buffer.contents(), count: dataSize)

        return ThumbnailResult(texture: texture, rawData: rawData, width: width, height: height, aspect: aspect)
    }

    /// Create a texture from raw BGRA data loaded from disk cache
    static func textureFromRawData(
        _ data: Data, width: Int, height: Int, device: MTLDevice
    ) -> MTLTexture? {
        let bytesPerRow = width * 4
        guard data.count == bytesPerRow * height else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        data.withUnsafeBytes { ptr in
            texture.replace(
                region: MTLRegion(origin: .init(), size: MTLSize(width: width, height: height, depth: 1)),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        return texture
    }

    // MARK: - Private Texture with Mipmaps

    private static func createTexture(
        from cgImage: CGImage, device: MTLDevice, commandQueue: MTLCommandQueue, mipmapped: Bool
    ) -> MTLTexture? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        let dataSize = bytesPerRow * height

        // Decode directly into a Metal shared buffer — eliminates intermediate CGContext malloc
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let stagingBuffer = device.makeBuffer(length: dataSize, options: .storageModeShared) else {
            return nil
        }

        guard let context = CGContext(
            data: stagingBuffer.contents(),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Create private (GPU-optimal) texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: mipmapped
        )
        descriptor.usage = mipmapped ? [.shaderRead, .shaderWrite] : .shaderRead
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        // Blit from staging buffer → private texture, then generate mipmaps
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }

        blit.copy(
            from: stagingBuffer,
            sourceOffset: 0,
            sourceBytesPerRow: bytesPerRow,
            sourceBytesPerImage: dataSize,
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin()
        )

        if mipmapped {
            blit.generateMipmaps(for: texture)
        }

        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return texture
    }

    // MARK: - RAW Detection & Preview

    private static let rawExtensions: Set<String> = [
        "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2", "dng", "pef", "srw", "x3f"
    ]

    static func isRawFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return rawExtensions.contains(ext)
    }

    static func loadPreviewTexture(
        from path: String, device: MTLDevice, commandQueue: MTLCommandQueue
    ) -> MTLTexture? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // Extract embedded JPEG preview — do NOT set CreateThumbnailFromImageAlways
        // which would force a full RAW decode
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              preview.width >= 1024 || preview.height >= 1024 else {
            return nil
        }
        return createTexture(from: preview, device: device, commandQueue: commandQueue, mipmapped: true)
    }

    // MARK: - Utility

    static func isImageFile(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey]),
              let contentType = resourceValues.contentType else {
            return false
        }
        return contentType.conforms(to: .image)
    }
}
