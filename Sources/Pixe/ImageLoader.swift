import Metal
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum ImageLoader {

    // MARK: - Display-Resolution Image Loading

    /// Load an image at display resolution. RAW files use embedded preview;
    /// non-RAW files use ImageIO downsampling to maxPixelSize.
    static func loadDisplayTexture(
        from path: String,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        maxPixelSize: Int = 4096,
        minRawPreviewLongSide: Int? = nil
    ) -> MTLTexture? {
        if isRawFile(path) {
            // Use embedded JPEG preview — no CIImage/CIContext Metal leak
            let requiredPreviewLongSide = minRawPreviewLongSide ?? max(1536, Int(Double(maxPixelSize) * 0.9))
            if let preview = loadPreviewTexture(
                from: path,
                device: device,
                maxPixelSize: maxPixelSize,
                minLongSide: requiredPreviewLongSide
            ) {
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
        let cacheData: Data
        let width: Int
        let height: Int
        let aspect: Float
    }

    static func generateThumbnail(
        path: String, device: MTLDevice, maxPixelSize: Int
    ) -> ThumbnailResult? {
        return autoreleasepool { () -> ThumbnailResult? in
            // Fast path: RAW files — extract embedded JPEG preview instead of full decode
            if isRawFile(path) {
                if let result = generateRawThumbnailFromPreview(path: path, device: device, maxPixelSize: maxPixelSize) {
                    return result
                }
                // Fall through to full decode if no usable preview
            }

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

            let result = thumbnailResultFromCGImage(cgImage, device: device)
            CGImageSourceRemoveCacheAtIndex(source, 0)
            return result
        }
    }

    /// Extract embedded JPEG preview from a RAW file and downsample to thumbnail size.
    /// Avoids full sensor decode — typically completes in ~10ms vs 1-5s.
    private static func generateRawThumbnailFromPreview(
        path: String, device: MTLDevice, maxPixelSize: Int
    ) -> ThumbnailResult? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // Do NOT set CreateThumbnailFromImageAlways — that forces full RAW decode
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              preview.width >= 16, preview.height >= 16 else {
            CGImageSourceRemoveCacheAtIndex(source, 0)
            return nil
        }

        let result = thumbnailResultFromCGImage(preview, device: device)
        CGImageSourceRemoveCacheAtIndex(source, 0)
        return result
    }

    /// Shared helper: render a CGImage into a ThumbnailResult using a heap buffer
    /// (not a Metal buffer) so memory is freed immediately via defer.
    private static func thumbnailResultFromCGImage(
        _ cgImage: CGImage, device: MTLDevice
    ) -> ThumbnailResult? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        let dataSize = bytesPerRow * height
        let aspect = Float(width) / Float(height)

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

        context.setBlendMode(.copy)
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

        guard let cacheData = compressCGImageToJPEG(cgImage, quality: 0.85) else { return nil }

        return ThumbnailResult(texture: texture, cacheData: cacheData, width: width, height: height, aspect: aspect)
    }

    /// Compress a CGImage to JPEG data in memory for disk caching.
    private static func compressCGImageToJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Create a texture from JPEG data loaded from disk cache.
    static func textureFromJPEGData(
        _ data: Data, device: MTLDevice
    ) -> (texture: MTLTexture, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

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

        context.setBlendMode(.copy)
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

        return (texture: texture, width: width, height: height)
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

        context.setBlendMode(.copy)
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
        from path: String, device: MTLDevice, maxPixelSize: Int, minLongSide: Int
    ) -> MTLTexture? {
        return autoreleasepool { () -> MTLTexture? in
            let url = URL(fileURLWithPath: path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

            // Extract embedded JPEG preview — do NOT set CreateThumbnailFromImageAlways
            // which would force a full RAW decode
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            let longSide = max(preview.width, preview.height)
            guard longSide >= minLongSide else {
                CGImageSourceRemoveCacheAtIndex(source, 0)
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

    // MARK: - Image Metadata

    static func imageMetadata(path: String) -> [(String, String)] {
        var result: [(String, String)] = []

        let filename = (path as NSString).lastPathComponent
        result.append(("File", filename))

        // File size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64 {
            result.append(("Size", formatFileSize(size)))
        }

        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return result
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]

        // Pixel dimensions
        if let w = properties[kCGImagePropertyPixelWidth] as? Int,
           let h = properties[kCGImagePropertyPixelHeight] as? Int {
            result.append(("Dimensions", "\(w) \u{00D7} \(h)"))
        }

        // DPI
        if let dpiW = properties[kCGImagePropertyDPIWidth] as? Double {
            result.append(("DPI", "\(Int(dpiW))"))
        }

        // Bit depth
        if let depth = properties[kCGImagePropertyDepth] as? Int {
            result.append(("Bit Depth", "\(depth)"))
        }

        // Color space
        if let colorModel = properties[kCGImagePropertyColorModel] as? String {
            result.append(("Color Model", colorModel))
        }

        // TIFF dict — camera make/model
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var camera = ""
        if let make = tiff[kCGImagePropertyTIFFMake] as? String {
            camera = make
        }
        if let model = tiff[kCGImagePropertyTIFFModel] as? String {
            if camera.isEmpty {
                camera = model
            } else if !model.hasPrefix(camera) {
                camera += " " + model
            } else {
                camera = model
            }
        }
        if !camera.isEmpty {
            result.append(("Camera", camera))
        }

        // Exif dict
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]

        if let lens = exif[kCGImagePropertyExifLensModel] as? String {
            result.append(("Lens", lens))
        }

        // Focal length
        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double {
            var text = "\(Int(fl))mm"
            if let fl35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int {
                text += " (\(fl35)mm equiv)"
            }
            result.append(("Focal Length", text))
        }

        // Exposure
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double {
            let shutterText: String
            if time >= 1 {
                shutterText = "\(time)s"
            } else {
                shutterText = "1/\(Int(round(1.0 / time)))s"
            }
            result.append(("Shutter", shutterText))
        }

        if let fNumber = exif[kCGImagePropertyExifFNumber] as? Double {
            result.append(("Aperture", String(format: "\u{0192}/%.1f", fNumber)))
        }

        if let isoArray = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int],
           let iso = isoArray.first {
            result.append(("ISO", "\(iso)"))
        }

        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            result.append(("Date", date))
        }

        return result
    }

    private static func formatFileSize(_ bytes: UInt64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
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
