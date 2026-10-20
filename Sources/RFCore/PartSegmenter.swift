import Foundation
import CoreImage
import CoreML

/// MediaPipe selfie_multiclass_256x256（Apache 2.0，見 Resources/MediaPipe-LICENSE.txt）的 Core ML 版本。
///
/// 每個人裁成方形送進 256×256 模型，類別圖再依原圖邊緣放大回裁切範圍，小人物也有足夠解析度。
final class PartSegmenter: @unchecked Sendable {
    static let side = 256
    static let modelName = "SelfieMulticlass"

    private let model: MLModel
    private let lock = NSLock()

    nonisolated(unsafe) private static var cached: PartSegmenter?
    private static let cacheLock = NSLock()

    static func shared() throws -> PartSegmenter {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached { return cached }
        guard let url = Bundle.module.url(forResource: modelName, withExtension: "mlmodelc") else {
            throw PersonParts.Failure.model(String(localized: "app 內找不到 \(modelName).mlmodelc", bundle: .module))
        }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let loaded = PartSegmenter(model: try MLModel(contentsOf: url, configuration: configuration))
            cached = loaded
            return loaded
        } catch {
            throw PersonParts.Failure.model("\(error)")
        }
    }

    private init(model: MLModel) {
        self.model = model
    }

    /// 回傳與分析影像同尺寸的類別遮罩；裁切範圍外為 0。
    /// `region` 為要送進模型的範圍（左下原點）；取方形並加 15% 邊界，模型才看得到頭髮邊緣與肩膀。
    func classMask(_ index: Int, region: CGRect, image: CIImage,
                   context: CIContext) throws -> PersonParts.Raster {
        let full = image.extent
        let side = max(region.width, region.height) * 1.15
        let crop = CGRect(x: region.midX - side / 2, y: region.midY - side / 2,
                          width: side, height: side).integral
        let n = Self.side
        let scale = CGFloat(n) / crop.width
        let input = image.clampedToExtent().cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true)
        var rgba = [Float](repeating: 0, count: n * n * 4)
        context.render(input, toBitmap: &rgba, rowBytes: n * 16, bounds: CGRect(x: 0, y: 0, width: n, height: n),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let probabilities = try predict(rgba)[index]

        // 模型輸出第 0 列是上方；轉成 CIImage 後以原圖亮度引導放大，邊緣貼齊實際輪廓。
        let small = CIImage(bitmapData: Data(probabilities), bytesPerRow: n, size: CGSize(width: n, height: n),
                            format: .L8, colorSpace: nil)
        let guide = image.clampedToExtent().cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let upsampled = guide.applyingFilter("CIEdgePreserveUpsampleFilter",
            parameters: ["inputSmallImage": small, "inputSpatialSigma": 3, "inputLumaSigma": 0.15])
            .transformed(by: CGAffineTransform(translationX: crop.minX, y: crop.minY))
        let placed = upsampled.cropped(to: crop.intersection(full))
            .composited(over: CIImage(color: .black).cropped(to: full))
        return PersonParts.raster(placed, context: context)
    }

    /// 輸入 RGBA float（第 0 列上方），回傳每個類別的 8-bit 機率圖。
    private func predict(_ rgba: [Float]) throws -> [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        let n = Self.side
        let array = try MLMultiArray(shape: [1, NSNumber(value: n), NSNumber(value: n), 3], dataType: .float32)
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        // 模型 metadata 的正規化為 (x − 127.5) / 127.5，即 0–1 對應到 −1…1。
        for i in 0..<(n * n) {
            for c in 0..<3 { pointer[i * 3 + c] = max(0, min(1, rgba[i * 4 + c])) * 2 - 1 }
        }
        let inputName = model.modelDescription.inputDescriptionsByName.keys.first!
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inputName: array]))
        guard let name = model.modelDescription.outputDescriptionsByName.keys.first,
              let result = output.featureValue(for: name)?.multiArrayValue else {
            throw PersonParts.Failure.model(String(localized: "模型沒有輸出", bundle: .module))
        }
        // 輸出 [1, 256, 256, 6]，各像素的類別機率。
        let classes = result.shape.last!.intValue
        var maps = [[UInt8]](repeating: [UInt8](repeating: 0, count: n * n), count: classes)
        let strides = result.strides.map(\.intValue)
        // strides 可能含對齊留白，依 strides 直接讀記憶體。
        func read(_ value: (Int) -> Float) {
            for row in 0..<n {
                for x in 0..<n {
                    for c in 0..<classes {
                        let v = value(row * strides[1] + x * strides[2] + c * strides[3])
                        maps[c][row * n + x] = UInt8(max(0, min(1, v)) * 255)
                    }
                }
            }
        }
        switch result.dataType {
        case .float16:
            let p = result.dataPointer.assumingMemoryBound(to: Float16.self)
            read { Float(p[$0]) }
        case .float32:
            let p = result.dataPointer.assumingMemoryBound(to: Float.self)
            read { p[$0] }
        default:
            throw PersonParts.Failure.model(String(localized: "不支援的輸出格式", bundle: .module))
        }
        return maps
    }
}
