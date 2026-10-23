import Foundation
import CoreImage
import CoreML
import Accelerate

public enum SuperResolutionError: Error, CustomStringConvertible {
    case modelUnavailable(String)
    case outputTooLarge

    public var description: String {
        switch self {
        case .modelUnavailable(let reason): return String(localized: "超解析度模型無法載入：\(reason)", bundle: .module)
        case .outputTooLarge: return String(localized: "超解析度輸出影像尺寸超出可處理範圍", bundle: .module)
        }
    }
}

/// Real-ESRGAN x2plus (BSD-3-Clause, see Resources/RealESRGAN-LICENSE.txt) run as a Core ML model on fixed
/// 256 px tiles. The model was trained on 8-bit sRGB, so callers use it for SDR output only.
public final class SuperResolution: @unchecked Sendable {
    static let tile = 256
    static let overlap = 16
    static let modelName = "RealESRGAN_x2plus"

    static func packInput(rgba: UnsafePointer<Float>, into values: UnsafeMutablePointer<Float>) {
        let plane = tile * tile
        var lower: Float = 0
        var upper: Float = 1
        for channel in 0..<3 {
            vDSP_vclip(rgba.advanced(by: channel), 4, &lower, &upper,
                       values.advanced(by: channel * plane), 1, vDSP_Length(plane))
        }
    }

    private let model: MLModel
    private let lock = NSLock()

    nonisolated(unsafe) private static var cached: SuperResolution?
    private static let cacheLock = NSLock()

    /// Loads the bundled model once; later calls reuse it.
    public static func shared() throws -> SuperResolution {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached { return cached }
        guard let url = Bundle.module.url(forResource: modelName, withExtension: "mlmodelc") else {
            throw SuperResolutionError.modelUnavailable(String(localized: "app 內找不到 \(modelName).mlmodelc", bundle: .module))
        }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let loaded = SuperResolution(model: try MLModel(contentsOf: url, configuration: configuration))
            cached = loaded
            return loaded
        } catch {
            throw SuperResolutionError.modelUnavailable("\(error)")
        }
    }

    private init(model: MLModel) {
        self.model = model
    }

    /// Returns `image` at exactly twice its size (origin at zero). Tiles overlap so seams fall outside kept cores.
    public func upscale2x(_ image: CIImage, context: CIContext) throws -> CIImage {
        let performanceInterval = RFPerformance.begin("SuperResolution")
        defer { RFPerformance.end("SuperResolution", performanceInterval) }
        lock.lock()
        defer { lock.unlock() }
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width >= 0, extent.height >= 0,
              extent.width <= CGFloat(Int.max / 16), extent.height <= CGFloat(Int.max / 16) else {
            throw SuperResolutionError.outputTooLarge
        }
        let width = Int(extent.width), height = Int(extent.height)
        let source = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .clampedToExtent()
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let tile = Self.tile, overlap = Self.overlap, core = tile - 2 * overlap
        let (outWidth, widthOverflow) = width.multipliedReportingOverflow(by: 2)
        let (outHeight, heightOverflow) = height.multipliedReportingOverflow(by: 2)
        let (outputPixelCount, pixelCountOverflow) = outWidth.multipliedReportingOverflow(by: outHeight)
        let (outputComponentCount, componentCountOverflow) = outputPixelCount.multipliedReportingOverflow(by: 4)
        let (outputByteCount, byteCountOverflow) = outputComponentCount.multipliedReportingOverflow(
            by: MemoryLayout<Float16>.size)
        let (bytesPerRow, rowBytesOverflow) = outWidth.multipliedReportingOverflow(
            by: 4 * MemoryLayout<Float16>.size)
        guard !widthOverflow, !heightOverflow, !pixelCountOverflow,
              !componentCountOverflow, !byteCountOverflow, !rowBytesOverflow else {
            throw SuperResolutionError.outputTooLarge
        }
        var data = Data(count: outputByteCount)
        var pixels = [Float](repeating: 0, count: tile * tile * 4)
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: tile), NSNumber(value: tile)], dataType: .float32)

        try data.withUnsafeMutableBytes { rawOutput in
            guard let baseAddress = rawOutput.baseAddress else {
                guard outputComponentCount == 0 else { throw SuperResolutionError.outputTooLarge }
                return
            }
            let output = baseAddress.bindMemory(to: Float16.self, capacity: outputComponentCount)
            output.initialize(repeating: 1, count: outputComponentCount)

            // Top-down coordinates: row 0 is the top of the image, matching bitmap rows.
            for coreY in stride(from: 0, to: height, by: core) {
                for coreX in stride(from: 0, to: width, by: core) {
                    try Task.checkCancellation()
                    let tileX = coreX - overlap, tileY = coreY - overlap
                    let bounds = CGRect(x: tileX, y: height - tileY - tile, width: tile, height: tile)
                    context.render(source, toBitmap: &pixels, rowBytes: tile * 16, bounds: bounds,
                                   format: .RGBAf, colorSpace: sRGB)
                    let values = input.dataPointer.assumingMemoryBound(to: Float.self)
                    pixels.withUnsafeBufferPointer { rgba in
                        Self.packInput(rgba: rgba.baseAddress!, into: values)
                    }
                    let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": input]))
                    guard let upscaled = result.featureValue(for: "output")?.multiArrayValue else {
                        throw SuperResolutionError.modelUnavailable(String(localized: "模型沒有 output", bundle: .module))
                    }
                    let strides = upscaled.strides.map(\.intValue)
                    func value(_ c: Int, _ y: Int, _ x: Int) -> Float {
                        let offset = c * strides[1] + y * strides[2] + x * strides[3]
                        switch upscaled.dataType {
                        case .float16: return Float(upscaled.dataPointer.assumingMemoryBound(to: Float16.self)[offset])
                        default: return upscaled.dataPointer.assumingMemoryBound(to: Float.self)[offset]
                        }
                    }
                    for y in (2 * coreY)..<min(2 * (coreY + core), outHeight) {
                        let ty = y - 2 * tileY
                        for x in (2 * coreX)..<min(2 * (coreX + core), outWidth) {
                            let tx = x - 2 * tileX
                            let o = (y * outWidth + x) * 4
                            for c in 0..<3 { output[o + c] = Float16(min(max(value(c, ty, tx), 0), 1)) }
                        }
                    }
                }
            }
        }
        return CIImage(bitmapData: data, bytesPerRow: bytesPerRow,
                       size: CGSize(width: outWidth, height: outHeight), format: .RGBAh, colorSpace: sRGB)
    }
}
