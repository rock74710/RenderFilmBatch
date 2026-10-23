import Foundation
import Metal
import CoreImage
import simd

private struct LUTTextureContentKey: Hashable {
    let size: Int
    let byteCount: Int
    let digest: UInt64
}

private struct LUTTextureLayout {
    let byteCount: Int
    let bytesPerRow: Int
    let bytesPerImage: Int
}

private struct LUTTextureCacheStats {
    let entries: Int
    let bytes: Int
    let hits: Int
    let uploads: Int
    let evictions: Int
}

struct LUTResourceStats {
    let lutTextureCacheEntries: Int
    let lutTextureCacheBytes: Int
    let lutTextureCacheHits: Int
    let lutTextureUploads: Int
    let lutTextureEvictions: Int
    let sourceScratchAllocations: Int
    let sourceScratchHits: Int
    let sourceScratchPooledCount: Int
    let sourceScratchPooledBytes: Int
}

/// CPU 端烘焙、GPU 端套用的 3D LUT。
///
/// 把 Layer A、perceptual color engine、tone mapping、gamut mapping 合成一顆
/// LUT，是為了讓預覽即時（§20「預覽反應速度優先」）：參數變動只需重算
/// 41³ 個點，而不是每個像素都重算整條色彩鏈。
public struct LUT3D: Sendable {
    public static let defaultSize = 41
    /// shaper 的範圍，以 0.18 中灰為 0 stop。
    public static let shaperLo: Double = -12
    public static let shaperHi: Double = 6

    public let size: Int
    /// RGBA float，長度 size³ * 4。
    public let data: [Float]
    private let textureContentDigest: UInt64

    public init(size: Int, data: [Float]) {
        self.size = size
        self.data = data
        self.textureContentDigest = Self.contentDigest(of: data)
    }

    public static func shaperDecode(_ x: Double) -> Double {
        0.18 * pow(2.0, shaperLo + x * (shaperHi - shaperLo))
    }

    public static func shaperEncode(_ v: Double) -> Double {
        let s = max(v, 1e-6)
        return min(max((log2(s / 0.18) - shaperLo) / (shaperHi - shaperLo), 0), 1)
    }

    /// 以 scene + target 兩段轉換烘焙出 LUT。
    public static func bake(
        scene: SceneTransform,
        target: TargetTransform,
        finishing: FinishingTransform? = nil,
        size: Int = defaultSize
    ) -> LUT3D {
        bake(size: size) { input in
            let display = target.apply(scene.apply(input))
            return finishing?.apply(display) ?? display
        }
    }

    /// 有局部調整時，分別烘焙 scene 與 target，保留中間的線性影像。
    public static func bake(size: Int = defaultSize, transform: @Sendable (SIMD3<Double>) -> SIMD3<Double>) -> LUT3D {
        var out = [Float](repeating: 0, count: size * size * size * 4)
        let axis = (0..<size).map { shaperDecode(Double($0) / Double(size - 1)) }

        // 每個 slice 互相獨立，直接平行化。
        out.withUnsafeMutableBufferPointer { buf in
            let ptr = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: size) { b in
                let bv = axis[b]
                for g in 0..<size {
                    let gv = axis[g]
                    for r in 0..<size {
                        let input = SIMD3(axis[r], gv, bv)
                        let result = transform(input)
                        // texture3d 的記憶體排列為 x 最快變動。
                        let index = ((b * size + g) * size + r) * 4
                        ptr[index + 0] = Float(result.x)
                        ptr[index + 1] = Float(result.y)
                        ptr[index + 2] = Float(result.z)
                        ptr[index + 3] = 1
                    }
                }
            }
        }
        return LUT3D(size: size, data: out)
    }

    /// CPU 端以三線性插值查表，供測試與非 GPU 環境使用。
    public func sample(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        func coord(_ v: Double) -> (Int, Int, Double) {
            let x = Self.shaperEncode(v) * Double(size - 1)
            let i0 = min(max(Int(floor(x)), 0), size - 1)
            let i1 = min(i0 + 1, size - 1)
            return (i0, i1, x - Double(i0))
        }
        let (r0, r1, rt) = coord(rgb.x)
        let (g0, g1, gt) = coord(rgb.y)
        let (b0, b1, bt) = coord(rgb.z)

        func fetch(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Double> {
            let i = ((b * size + g) * size + r) * 4
            return SIMD3(Double(data[i]), Double(data[i + 1]), Double(data[i + 2]))
        }
        func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
            a + (b - a) * t
        }

        let c00 = mix(fetch(r0, g0, b0), fetch(r1, g0, b0), rt)
        let c10 = mix(fetch(r0, g1, b0), fetch(r1, g1, b0), rt)
        let c01 = mix(fetch(r0, g0, b1), fetch(r1, g0, b1), rt)
        let c11 = mix(fetch(r0, g1, b1), fetch(r1, g1, b1), rt)
        return mix(mix(c00, c10, gt), mix(c01, c11, gt), bt)
    }

    /// 上傳成 Metal 3D texture。
    public func makeTexture(device: MTLDevice) -> MTLTexture? {
        guard let layout = validatedTextureLayout() else { return nil }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba32Float
        d.width = size; d.height = size; d.depth = size
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        data.withUnsafeBytes { raw in
            tex.replace(
                region: MTLRegionMake3D(0, 0, 0, size, size, size),
                mipmapLevel: 0,
                slice: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: layout.bytesPerRow,
                bytesPerImage: layout.bytesPerImage
            )
        }
        return tex
    }

    fileprivate func textureCacheIdentity() -> (key: LUTTextureContentKey, byteCount: Int)? {
        guard let layout = validatedTextureLayout() else { return nil }
        // Account for both the GPU texture and the retained CPU snapshot used to
        // verify the digest before reporting a cache hit.
        let (retainedByteCount, retainedByteOverflow) = layout.byteCount.multipliedReportingOverflow(by: 2)
        guard !retainedByteOverflow else { return nil }
        return (
            LUTTextureContentKey(size: size, byteCount: layout.byteCount, digest: textureContentDigest),
            retainedByteCount
        )
    }

    private static func contentDigest(of data: [Float]) -> UInt64 {
        data.withUnsafeBytes { raw -> UInt64 in
            var value: UInt64 = 14_695_981_039_346_656_037
            for byte in raw {
                value = (value ^ UInt64(byte)) &* 1_099_511_628_211
            }
            return value
        }
    }

    private func validatedTextureLayout() -> LUTTextureLayout? {
        guard size > 0 else { return nil }
        let (sizeSquared, squareOverflow) = size.multipliedReportingOverflow(by: size)
        let (voxelCount, voxelOverflow) = sizeSquared.multipliedReportingOverflow(by: size)
        let (floatCount, floatOverflow) = voxelCount.multipliedReportingOverflow(by: 4)
        let (byteCount, byteOverflow) = floatCount.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        let (rowFloatCount, rowFloatOverflow) = size.multipliedReportingOverflow(by: 4)
        let (bytesPerRow, rowByteOverflow) = rowFloatCount.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        let (imageFloatCount, imageFloatOverflow) = sizeSquared.multipliedReportingOverflow(by: 4)
        let (bytesPerImage, imageByteOverflow) = imageFloatCount.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !squareOverflow, !voxelOverflow, !floatOverflow, !byteOverflow,
              !rowFloatOverflow, !rowByteOverflow, !imageFloatOverflow, !imageByteOverflow,
              data.count == floatCount else { return nil }
        return LUTTextureLayout(byteCount: byteCount, bytesPerRow: bytesPerRow, bytesPerImage: bytesPerImage)
    }
}

struct LUTParamsGPU {
    var shaperLo: Float
    var shaperHi: Float
    var lutSize: Float
    var sourceYOffset: UInt32
}

/// 在 GPU 上套用 LUT。與 `OpticalRenderer` 共用同一個 command queue。
public final class LUTRenderer: @unchecked Sendable {
    private static let maximumSourcePixels = 8 * 1_024 * 1_024

    private let gpu: GPUContext
    private let pipeline: MTLComputePipelineState
    private let lutTextureCache: LUTTextureContentCache
    private let maximumSourceRows: Int?

    public convenience init(gpu: GPUContext) throws {
        try self.init(gpu: gpu, lutTextureCacheEntryLimit: 8,
                      lutTextureCacheByteLimit: 16 * 1_024 * 1_024,
                      maximumSourceRows: nil)
    }

    convenience init(gpu: GPUContext, maximumSourceRows: Int) throws {
        try self.init(gpu: gpu, lutTextureCacheEntryLimit: 8,
                      lutTextureCacheByteLimit: 16 * 1_024 * 1_024,
                      maximumSourceRows: maximumSourceRows)
    }

    init(gpu: GPUContext, lutTextureCacheEntryLimit: Int, lutTextureCacheByteLimit: Int,
         maximumSourceRows: Int? = nil) throws {
        self.gpu = gpu
        self.pipeline = try gpu.makePipeline(function: "rf_apply_lut")
        self.lutTextureCache = LUTTextureContentCache(
            maximumEntries: lutTextureCacheEntryLimit,
            maximumBytes: lutTextureCacheByteLimit
        )
        self.maximumSourceRows = maximumSourceRows.map { max(1, $0) }
    }

    var resourceStats: LUTResourceStats {
        let lut = lutTextureCache.stats
        let scratch = gpu.sourceScratchStats
        return LUTResourceStats(
            lutTextureCacheEntries: lut.entries,
            lutTextureCacheBytes: lut.bytes,
            lutTextureCacheHits: lut.hits,
            lutTextureUploads: lut.uploads,
            lutTextureEvictions: lut.evictions,
            sourceScratchAllocations: scratch.allocations,
            sourceScratchHits: scratch.hits,
            sourceScratchPooledCount: scratch.pooledCount,
            sourceScratchPooledBytes: scratch.pooledBytes
        )
    }

    public func apply(to image: CIImage, lut: LUT3D, outputColorSpace: CGColorSpace) throws -> CIImage {
        let performanceInterval = RFPerformance.begin("LUTSynchronous")
        defer { RFPerformance.end("LUTSynchronous", performanceInterval) }
        let extent = image.extent.isInfinite
            ? CGRect(x: 0, y: 0, width: 2048, height: 2048) : image.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0,
              extent.width < CGFloat(Int.max), extent.height < CGFloat(Int.max) else { return image }
        let w = Int(extent.width.rounded()), h = Int(extent.height.rounded())
        guard w > 0, h > 0,
              let lutTexture = lutTextureCache.texture(for: lut, device: gpu.device) else { return image }

        let dest = try gpu.makeTexture(width: w, height: h)
        let rowsByPixelBudget = max(1, Self.maximumSourcePixels / w)
        let stripHeight = min(h, maximumSourceRows ?? rowsByPixelBudget)
        var yOffset = 0
        while yOffset < h {
            let rows = min(stripHeight, h - yOffset)
            let source = try gpu.acquireSourceScratch(width: w, height: rows)
            guard let buffer = gpu.commandQueue.makeCommandBuffer() else {
                gpu.recycleSourceScratch(source)
                return image
            }

            let translated = image.transformed(by: CGAffineTransform(
                translationX: -extent.origin.x,
                y: -(extent.origin.y + CGFloat(yOffset))
            ))
            gpu.ciContext.render(
                translated,
                to: source,
                commandBuffer: buffer,
                bounds: CGRect(x: 0, y: 0, width: w, height: rows),
                colorSpace: gpu.workingColorSpace
            )

            var params = LUTParamsGPU(
                shaperLo: Float(LUT3D.shaperLo),
                shaperHi: Float(LUT3D.shaperHi),
                lutSize: Float(lut.size),
                sourceYOffset: UInt32(yOffset)
            )
            guard let enc = buffer.makeComputeCommandEncoder() else {
                buffer.commit()
                buffer.waitUntilCompleted()
                gpu.recycleSourceScratch(source)
                return image
            }
            enc.setComputePipelineState(pipeline)
            enc.setTexture(source, index: 0)
            enc.setTexture(dest, index: 1)
            enc.setTexture(lutTexture, index: 2)
            enc.setBytes(&params, length: MemoryLayout<LUTParamsGPU>.stride, index: 0)
            enc.dispatchThreadgroups(
                MTLSize(width: (w + 15) / 16, height: (rows + 15) / 16, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
            )
            enc.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            gpu.recycleSourceScratch(source)
            yOffset += rows
        }

        // LUT 輸出已經是目標色域的編碼值，所以掛上目標色彩空間。
        guard let wrapped = CIImage(mtlTexture: dest, options: [.colorSpace: outputColorSpace])
        else { return image }
        // 同 OpticalRenderer：render(to:) 與 CIImage(mtlTexture:) 的 y 軸已互相抵銷，
        // 不需要額外翻轉（A-003）。
        return wrapped
            .transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
    }
}

private final class LUTTextureContentCache {
    private struct Entry {
        let texture: MTLTexture
        let data: [Float]
        let byteCount: Int
        var accessOrder: UInt64
    }

    private let lock = NSLock()
    private let maximumEntries: Int
    private let maximumBytes: Int
    private var entries: [LUTTextureContentKey: Entry] = [:]
    private var cachedBytes = 0
    private var nextAccessOrder: UInt64 = 0
    private var hitCount = 0
    private var uploadCount = 0
    private var evictionCount = 0

    init(maximumEntries: Int, maximumBytes: Int) {
        self.maximumEntries = max(maximumEntries, 0)
        self.maximumBytes = max(maximumBytes, 0)
    }

    func texture(for lut: LUT3D, device: MTLDevice) -> MTLTexture? {
        guard let identity = lut.textureCacheIdentity() else { return nil }
        lock.lock()
        defer { lock.unlock() }

        if var entry = entries[identity.key] {
            if Self.hasSameBits(entry.data, lut.data) {
                hitCount += 1
                nextAccessOrder &+= 1
                entry.accessOrder = nextAccessOrder
                entries[identity.key] = entry
                return entry.texture
            }
            // A digest collision is safe: discard the old entry and upload this content.
            removeEntry(for: identity.key)
            evictionCount += 1
        }

        guard let texture = lut.makeTexture(device: device) else { return nil }
        uploadCount += 1
        guard maximumEntries > 0, identity.byteCount <= maximumBytes else { return texture }

        while entries.count >= maximumEntries || cachedBytes > maximumBytes - identity.byteCount {
            guard let oldest = entries.min(by: { $0.value.accessOrder < $1.value.accessOrder })?.key else { break }
            removeEntry(for: oldest)
            evictionCount += 1
        }
        nextAccessOrder &+= 1
        entries[identity.key] = Entry(
            texture: texture,
            data: lut.data,
            byteCount: identity.byteCount,
            accessOrder: nextAccessOrder
        )
        cachedBytes += identity.byteCount
        return texture
    }

    var stats: LUTTextureCacheStats {
        lock.lock()
        defer { lock.unlock() }
        return LUTTextureCacheStats(
            entries: entries.count,
            bytes: cachedBytes,
            hits: hitCount,
            uploads: uploadCount,
            evictions: evictionCount
        )
    }

    private func removeEntry(for key: LUTTextureContentKey) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        cachedBytes -= removed.byteCount
    }

    private static func hasSameBits(_ lhs: [Float], _ rhs: [Float]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in left.bitPattern == right.bitPattern }
    }
}
