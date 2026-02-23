import Metal
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum ImageLoader {

    // MARK: - Display-Resolution Image Loading

    /// Load an image at display resolution. RAW files use embedded preview;
    /// non-RAW files use ImageIO downsampling to maxPixelSize.
    static func loadDisplayTexture(
        from path: String, device: MTLDevice, commandQueue: MTLCommandQueue, maxPixelSize: Int = 4096
    ) -> MTLTexture? {
        if isRawFile(path) {
            // Use embedded JPEG preview — no CIImage/CIContext Metal leak
            if let preview = loadPreviewTexture(from: path, device: device, commandQueue: commandQueue) {
                return preview
            }
            // Fallback: decode RAW at reduced resolution via ImageIO
        }
        return loadStandardDisplayTexture(from: path, device: device, commandQueue: commandQueue, maxPixelSize: maxPixelSize)
    }

    /// Decode a standard image (JPEG, PNG, HEIC, WebP, etc.) downsampled to
    /// maxPixelSize during decode. Images smaller than maxPixelSize are not upscaled.
    private static func loadStandardDisplayTexture(
        from path: String, device: MTLDevice, commandQueue: MTLCommandQueue, maxPixelSize: Int
    ) -> MTLTexture? {
        return autoreleasepool { () -> MTLTexture? in
            let url = URL(fileURLWithPath: path)

            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }

            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                return nil
            }

            MemoryProfiler.logEvent("loadDisplayTexture: decoded \(image.width)×\(image.height) from \((path as NSString).lastPathComponent)", device: device)
            let texture = createSharedTexture(from: image, device: device)
            if let tex = texture {
                MemoryProfiler.logTextureCreated("loadDisplayTexture", texture: tex, device: device)
            }

            CGImageSourceRemoveCacheAtIndex(imageSource, 0)
            return texture
        }
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
        return autoreleasepool { () -> ThumbnailResult? in
            let url = URL(fileURLWithPath: path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }

            let aspect = Float(cgImage.width) / Float(cgImage.height)
            let width = cgImage.width
            let height = cgImage.height
            let bytesPerRow = width * 4
            let dataSize = bytesPerRow * height

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

            let rawData = Data(bytes: buffer.contents(), count: dataSize)

            CGImageSourceRemoveCacheAtIndex(source, 0)

            return ThumbnailResult(texture: texture, rawData: rawData, width: width, height: height, aspect: aspect)
        }
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

    // MARK: - Shared Texture (no staging buffer)

    /// Create a shared, non-mipmapped texture directly from a CGImage.
    /// Decodes into a temporary heap buffer (freed immediately via defer),
    /// then copies to a shared texture via replace(). No Metal staging buffer
    /// or blit command — eliminates the RSS growth from lingering Metal buffers.
    private static func createSharedTexture(
        from cgImage: CGImage, device: MTLDevice
    ) -> MTLTexture? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        let dataSize = bytesPerRow * height

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let rawBuffer = UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 16)
        defer { rawBuffer.deallocate() }

        guard let context = CGContext(
            data: rawBuffer,
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
            withBytes: rawBuffer,
            bytesPerRow: bytesPerRow
        )

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
        return autoreleasepool { () -> MTLTexture? in
            let url = URL(fileURLWithPath: path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

            // Extract embedded JPEG preview — do NOT set CreateThumbnailFromImageAlways
            // which would force a full RAW decode
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  preview.width >= 1024 || preview.height >= 1024 else {
                return nil
            }
            MemoryProfiler.logEvent("loadPreview: \(preview.width)×\(preview.height) from \((path as NSString).lastPathComponent)", device: device)
            let texture = createSharedTexture(from: preview, device: device)
            if let tex = texture {
                MemoryProfiler.logTextureCreated("RAW preview", texture: tex, device: device)
            }

            CGImageSourceRemoveCacheAtIndex(source, 0)

            return texture
        }
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
