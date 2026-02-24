import Foundation
import Metal

/// Lightweight memory profiler — press 'M' in image mode to dump stats.
/// Also logs automatically on key events (image load, prefetch, thumbnail batch).
enum MemoryProfiler {
    static var enabled = false

    // MARK: - Process Memory

    /// Resident memory (RSS) in bytes — what Activity Monitor shows
    static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    /// Virtual memory in bytes
    static func virtualMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.virtual_size : 0
    }

    // MARK: - Metal Device Memory

    /// Current allocated size reported by the Metal device
    static func metalAllocatedSize(_ device: MTLDevice) -> Int {
        return device.currentAllocatedSize
    }

    // MARK: - Texture Size Estimation

    /// Estimate GPU memory for a texture including mipmaps
    static func textureBytes(_ texture: MTLTexture) -> Int {
        var total = 0
        var w = texture.width
        var h = texture.height
        let bpp = bytesPerPixel(texture.pixelFormat)
        for level in 0 ..< texture.mipmapLevelCount {
            _ = level
            total += w * h * bpp
            w = max(1, w / 2)
            h = max(1, h / 2)
        }
        return total
    }

    private static func bytesPerPixel(_ format: MTLPixelFormat) -> Int {
        switch format {
        case .bgra8Unorm, .rgba8Unorm, .bgra8Unorm_srgb, .rgba8Unorm_srgb:
            return 4
        case .rgba16Float:
            return 8
        case .rgba32Float:
            return 16
        default:
            return 4  // reasonable fallback
        }
    }

    // MARK: - Formatting

    static func formatBytes(_ bytes: Int) -> String {
        formatBytes(UInt64(bytes))
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0)
        } else if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        } else if bytes >= 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        }
        return "\(bytes) B"
    }

    static func textureSummary(_ texture: MTLTexture) -> String {
        let size = textureBytes(texture)
        let storage: String
        switch texture.storageMode {
        case .shared: storage = "shared"
        case .private: storage = "private"
        case .managed: storage = "managed"
        case .memoryless: storage = "memoryless"
        @unknown default: storage = "unknown"
        }
        return "\(texture.width)×\(texture.height) mip=\(texture.mipmapLevelCount) \(storage) [\(formatBytes(size))]"
    }

    // MARK: - Full Report

    struct Report {
        let rss: UInt64
        let virtual: UInt64
        let metalAllocated: Int
        let prefetchEntries: [(path: String, size: Int, dims: String)]
        let thumbnailCount: Int
        let thumbnailTotalBytes: Int
        let currentTextureInfo: String?
    }

    static func printReport(_ report: Report) {
        print("╔══════════════════════════════════════════════════╗")
        print("║           PIXE MEMORY PROFILE                   ║")
        print("╠══════════════════════════════════════════════════╣")
        print("║ Process RSS:       \(pad(formatBytes(report.rss)))")
        print("║ Process Virtual:   \(pad(formatBytes(report.virtual)))")
        print("║ Metal Allocated:   \(pad(formatBytes(report.metalAllocated)))")
        print("╠══════════════════════════════════════════════════╣")

        if let current = report.currentTextureInfo {
            print("║ Current Texture:   \(pad(current))")
        }

        print("║ Prefetch Cache:    \(pad("\(report.prefetchEntries.count) entries"))")
        var prefetchTotal = 0
        for entry in report.prefetchEntries {
            let name = (entry.path as NSString).lastPathComponent
            print("║   \(pad("\(name): \(entry.dims) \(formatBytes(entry.size))"))")
            prefetchTotal += entry.size
        }
        print("║   Total:           \(pad(formatBytes(prefetchTotal)))")

        print("╠══════════════════════════════════════════════════╣")
        print("║ Thumbnail Cache:   \(pad("\(report.thumbnailCount) textures"))")
        print("║   Total:           \(pad(formatBytes(report.thumbnailTotalBytes)))")
        print("╠══════════════════════════════════════════════════╣")

        let tracked = prefetchTotal + report.thumbnailTotalBytes
        print("║ Tracked Textures:  \(pad(formatBytes(tracked)))")
        let unaccounted = report.metalAllocated - tracked
        if unaccounted > 0 {
            print("║ Untracked Metal:   \(pad(formatBytes(unaccounted)))")
        }
        let overhead = Int(report.rss) - report.metalAllocated
        if overhead > 0 {
            print("║ Non-Metal (RSS):   \(pad(formatBytes(overhead)))")
        }
        print("╚══════════════════════════════════════════════════╝")
    }

    private static func pad(_ s: String) -> String {
        let target = 30
        if s.count >= target { return s + " ║" }
        return s + String(repeating: " ", count: target - s.count) + "║"
    }

    // MARK: - Event Logging

    static func logEvent(_ event: String, device: MTLDevice) {
        guard enabled else { return }
        let rss = formatBytes(residentMemoryBytes())
        let metal = formatBytes(metalAllocatedSize(device))
        print("[mem] \(event) | RSS: \(rss) | Metal: \(metal)")
    }

    static func logPerf(_ message: String) {
        guard enabled else { return }
        print("[perf] \(message)")
    }

    static func logTextureCreated(_ label: String, texture: MTLTexture, device: MTLDevice) {
        guard enabled else { return }
        let texInfo = textureSummary(texture)
        logEvent("\(label): \(texInfo)", device: device)
    }
}
