import Foundation
import Metal
import CoreImage

public enum GPUError: Error, CustomStringConvertible {
    case noDevice
    case noCommandQueue
    case shaderLibraryUnavailable(String)
    case functionMissing(String)
    case textureAllocationFailed

    public var description: String {
        switch self {
        case .noDevice: return String(localized: "找不到 Metal 裝置", bundle: .module)
        case .noCommandQueue: return String(localized: "無法建立 Metal command queue", bundle: .module)
        case .shaderLibraryUnavailable(let s): return String(localized: "無法載入 Metal shader library：\(s)", bundle: .module)
        case .functionMissing(let n): return String(localized: "Metal shader 缺少函式：\(n)", bundle: .module)
        case .textureAllocationFailed: return String(localized: "無法建立 Metal texture", bundle: .module)
        }
    }
}

struct SourceScratchPoolStats {
    let allocations: Int
    let hits: Int
    let pooledCount: Int
    let pooledBytes: Int
}

private struct SourceScratchKey: Hashable {
    let width: Int
    let height: Int
}

/// §16：Core Image 與自寫 Metal pass 共用同一個 device 與 command queue，
/// 讓整條 pipeline 留在 GPU 上，避免 GPU → CPU → GPU 往返。
public final class GPUContext: @unchecked Sendable {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let ciContext: CIContext
    /// 內部 working space 的 CGColorSpace：extended linear，不做早期 clamp。
    public let workingColorSpace: CGColorSpace

    public static let shared: GPUContext? = try? GPUContext()

    private let sourceScratchLock = NSLock()
    private var sourceScratchTextures: [SourceScratchKey: [MTLTexture]] = [:]
    private var sourceScratchPooledCount = 0
    private var sourceScratchPooledBytes = 0
    private var sourceScratchAllocations = 0
    private var sourceScratchHits = 0
    private let sourceScratchMaximumCount = 8
    private let sourceScratchMaximumBytes = 64 * 1_024 * 1_024

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw GPUError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw GPUError.noCommandQueue }
        self.device = device
        self.commandQueue = queue
        self.workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        self.ciContext = CIContext(
            mtlCommandQueue: queue,
            options: [
                .workingColorSpace: workingColorSpace,
                .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
                .cacheIntermediates: true,
                .highQualityDownsample: true,
            ]
        )
    }

    private var libraryCache: MTLLibrary?

    /// 由 SwiftPM 產生的 `default.metallib`（在 Bundle.module 內）載入 shader。
    public func shaderLibrary() throws -> MTLLibrary {
        if let libraryCache { return libraryCache }
        if let lib = try? device.makeDefaultLibrary(bundle: Bundle.module) {
            libraryCache = lib
            return lib
        }
        // 後備路徑：直接找 bundle 內的 metallib 檔案。
        if let url = Bundle.module.url(forResource: "default", withExtension: "metallib"),
           let lib = try? device.makeLibrary(URL: url) {
            libraryCache = lib
            return lib
        }
        throw GPUError.shaderLibraryUnavailable(Bundle.module.bundlePath)
    }

    public func makePipeline(function name: String) throws -> MTLComputePipelineState {
        let lib = try shaderLibrary()
        guard let fn = lib.makeFunction(name: name) else { throw GPUError.functionMissing(name) }
        return try device.makeComputePipelineState(function: fn)
    }

    public func makeTexture(width: Int, height: Int,
                            usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) throws -> MTLTexture {
        guard width > 0, height > 0,
              Self.rgba16FloatByteCount(width: width, height: height) != nil else {
            throw GPUError.textureAllocationFailed
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        d.usage = usage
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { throw GPUError.textureAllocationFailed }
        return t
    }

    func acquireSourceScratch(width: Int, height: Int) throws -> MTLTexture {
        guard let byteCount = Self.rgba16FloatByteCount(width: width, height: height) else {
            throw GPUError.textureAllocationFailed
        }
        sourceScratchLock.lock()
        defer { sourceScratchLock.unlock() }

        let key = SourceScratchKey(width: width, height: height)
        if var bucket = sourceScratchTextures[key], let texture = bucket.popLast() {
            sourceScratchTextures[key] = bucket.isEmpty ? nil : bucket
            sourceScratchPooledCount -= 1
            sourceScratchPooledBytes -= byteCount
            sourceScratchHits += 1
            return texture
        }

        let texture = try makeTexture(width: width, height: height)
        sourceScratchAllocations += 1
        return texture
    }

    /// Return only a source texture whose command buffer has completed.
    func recycleSourceScratch(_ texture: MTLTexture) {
        guard texture.pixelFormat == .rgba16Float,
              let byteCount = Self.rgba16FloatByteCount(width: texture.width, height: texture.height) else {
            return
        }

        sourceScratchLock.lock()
        defer { sourceScratchLock.unlock() }
        guard sourceScratchPooledCount < sourceScratchMaximumCount,
              byteCount <= sourceScratchMaximumBytes,
              sourceScratchPooledBytes <= sourceScratchMaximumBytes - byteCount else {
            return
        }

        let key = SourceScratchKey(width: texture.width, height: texture.height)
        sourceScratchTextures[key, default: []].append(texture)
        sourceScratchPooledCount += 1
        sourceScratchPooledBytes += byteCount
    }

    var sourceScratchStats: SourceScratchPoolStats {
        sourceScratchLock.lock()
        defer { sourceScratchLock.unlock() }
        return SourceScratchPoolStats(
            allocations: sourceScratchAllocations,
            hits: sourceScratchHits,
            pooledCount: sourceScratchPooledCount,
            pooledBytes: sourceScratchPooledBytes
        )
    }

    private static func rgba16FloatByteCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow else { return nil }
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4 * MemoryLayout<UInt16>.size)
        return byteOverflow ? nil : bytes
    }
}
