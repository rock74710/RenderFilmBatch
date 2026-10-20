import Foundation
import CoreImage
import CoreML
import CoreVideo
import CryptoKit

public enum RetouchAIError: Error, LocalizedError {
    case unavailable, invalidModel, invalidImage, corruptDownload, http(Int)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return String(localized: "請先下載本機 AI 修補模型。", bundle: .module)
        case .invalidModel: return String(localized: "AI 修補模型格式不符，請重新下載。", bundle: .module)
        case .invalidImage: return String(localized: "AI 修補區域無效。", bundle: .module)
        case .corruptDownload: return String(localized: "模型下載校驗失敗，請重試。", bundle: .module)
        case .http(let status): return String(localized: "模型下載失敗（HTTP \(status)）。", bundle: .module)
        }
    }
}

/// LaMa 開源補洞模型，在 Core ML 本機執行；照片不送到模型下載伺服器。
public enum RetouchAIModel {
    public static let revision = "5ed76e3799ab4cad31381750d29880c267477e18"
    public static let downloadBytes: Int64 = 216_647_386
    static func tileAxisBlendWeights(tileIndex: Int, tileCount: Int, reverseOrder: Bool = false) -> [Float] {
        let bitmapIndex = reverseOrder ? tileCount - tileIndex - 1 : tileIndex
        let coreInset = 64, coreEnd = 736
        var result = [Float](repeating: 1, count: 800)
        func smooth(_ value: Float) -> Float { value * value * (3 - 2 * value) }
        if bitmapIndex > 0 {
            for position in coreInset..<(coreInset + 32) {
                result[position] = smooth(Float(position - coreInset) / 32)
            }
        }
        if bitmapIndex + 1 < tileCount {
            for position in (coreEnd - 32)..<coreEnd {
                result[position] = smooth(Float(coreEnd - position) / 32)
            }
        }
        return result
    }

    private static let assets: [(String, Int64, String)] = [
        ("Manifest.json", 617, "c814fff3cedf827c044094545ef80b0280b6cb8dd0e5c0bcf69fd31921191e58"),
        ("Data/com.apple.CoreML/model.mlmodel", 1_101_809, "06a100ef99e0fd16326a3a8c4a687d13f7b26f544ea906a75338932d8554f953"),
        ("Data/com.apple.CoreML/weights/weight.bin", 215_544_960, "d0541f6044a94cd4982bfdac074fc1ccfe11d8f1f590c299d6b5071b501fc184"),
    ]

    public static var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RenderFilm/Models/LaMa-\(revision).mlmodelc", isDirectory: true)
    }

    public static var isInstalled: Bool {
        (try? String(contentsOf: modelDirectory.appendingPathComponent("RenderFilm.version"), encoding: .utf8)) == revision
    }

    public static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        if isInstalled { progress(1); return }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("RenderFilm-LaMa-\(UUID().uuidString)", isDirectory: true)
        let package = staging.appendingPathComponent("LaMa.mlpackage", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var finished: Int64 = 0
        for (path, size, expectedHash) in assets {
            try Task.checkCancellation()
            let destination = package.appendingPathComponent(path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let url = URL(string: "https://huggingface.co/mlboydaisuke/LaMa-CoreML/resolve/\(revision)/LaMa.mlpackage/\(path)")!
            let base = finished
            try await ModelAssetDownload.fetch(url: url, to: destination) { bytes in
                progress(min(0.9, Double(base + bytes) / Double(downloadBytes) * 0.9))
            }
            let actualSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard actualSize == Int(size), try hash(destination) == expectedHash else { throw RetouchAIError.corruptDownload }
            finished += size
        }
        try Task.checkCancellation()
        progress(0.92)
        let compiled = try await MLModel.compileModel(at: package)
        defer { try? fm.removeItem(at: compiled) }
        try Task.checkCancellation()
        // 先驗證模型輸入輸出，完整複製後才發布安裝完成標記。
        _ = try LoadedModel(url: compiled)
        let target = modelDirectory
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pending = target.deletingLastPathComponent().appendingPathComponent("LaMa-\(UUID().uuidString).pending", isDirectory: true)
        defer { try? fm.removeItem(at: pending) }
        try fm.copyItem(at: compiled, to: pending)
        try revision.write(to: pending.appendingPathComponent("RenderFilm.version"), atomically: true, encoding: .utf8)
        try Task.checkCancellation()
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: pending)
        } else {
            try fm.moveItem(at: pending, to: target)
        }
        progress(1)
    }

    private static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            try Task.checkCancellation()
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: LoadedModel?

    public static func fill(image: CIImage, mask: CIImage, context: CIContext) throws -> CIImage {
        guard isInstalled else { throw RetouchAIError.unavailable }
        let model: LoadedModel = try cacheLock.withLock {
            if let cached { return cached }
            let loaded = try LoadedModel(url: modelDirectory)
            cached = loaded
            return loaded
        }
        return try model.fill(image: image, mask: mask, context: context)
    }

    /// 測試明確指定模型，不改使用者安裝狀態。
    static func fill(image: CIImage, mask: CIImage, context: CIContext, modelAt url: URL) throws -> CIImage {
        try LoadedModel(url: url).fill(image: image, mask: mask, context: context)
    }

    private final class LoadedModel: @unchecked Sendable {
        let model: MLModel
        let lock = NSLock()
        init(url: URL) throws {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            model = try MLModel(contentsOf: url, configuration: configuration)
            let inputs = model.modelDescription.inputDescriptionsByName
            guard let image = inputs["image"]?.imageConstraint,
                  let mask = inputs["mask"]?.imageConstraint,
                  image.pixelsWide == 800, image.pixelsHigh == 800,
                  mask.pixelsWide == 800, mask.pixelsHigh == 800,
                  model.modelDescription.outputDescriptionsByName["output"]?.type == .image else {
                throw RetouchAIError.invalidModel
            }
        }

        func fill(image: CIImage, mask: CIImage, context: CIContext) throws -> CIImage {
            try lock.withLock {
                try Task.checkCancellation()
                let extent = image.extent
                guard !extent.isEmpty, !extent.isInfinite,
                      extent.origin.x.isFinite, extent.origin.y.isFinite,
                      extent.width.isFinite, extent.height.isFinite,
                      mask.extent == extent else { throw RetouchAIError.invalidImage }
                let size = CGFloat(800), span = max(extent.width, extent.height)
                let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
                let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
                let peak = Self.exposurePeak(image, extent: extent, context: context, colorSpace: linear)
                if span > size {
                    return try fillTiled(image: image, mask: mask, context: context,
                                         peak: Double(peak), linear: linear, srgb: srgb)
                }
                let square = CGRect(x: extent.midX - span / 2, y: extent.midY - span / 2, width: span, height: span)
                let transform = CGAffineTransform(translationX: -square.minX, y: -square.minY)
                    .concatenating(CGAffineTransform(scaleX: size / span, y: size / span))
                let bounds = CGRect(x: 0, y: 0, width: size, height: size)
                // SDR 訓練模型：局部高光先縮進模型範圍，輸出再恢復同一局部曝光尺度。
                // 此近似不會改遮罩外像素；生成高光仍需目視檢查。
                let normalized = Self.exposure(image, gain: 1 / Double(peak))
                    .clampedToExtent().cropped(to: square).transformed(by: transform)
                let black = CIImage(color: .black).cropped(to: square)
                let paddedMask = mask.cropped(to: extent).composited(over: black).transformed(by: transform)
                let imageBuffer = try Self.buffer(format: kCVPixelFormatType_32BGRA)
                let maskBuffer = try Self.buffer(format: kCVPixelFormatType_OneComponent8)
                context.render(normalized, to: imageBuffer, bounds: bounds, colorSpace: srgb)
                context.render(paddedMask, to: maskBuffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceGray())
                let provider = try MLDictionaryFeatureProvider(dictionary: [
                    "image": MLFeatureValue(pixelBuffer: imageBuffer),
                    "mask": MLFeatureValue(pixelBuffer: maskBuffer),
                ])
                let prediction = try model.prediction(from: provider)
                try Task.checkCancellation()
                guard let output = prediction.featureValue(for: "output")?.imageBufferValue else { throw RetouchAIError.invalidModel }
                let result = CIImage(cvPixelBuffer: output, options: [.colorSpace: srgb])
                    .transformed(by: transform.inverted()).cropped(to: extent)
                return Self.exposure(result, gain: Double(peak))
            }
        }

        private func fillTiled(image: CIImage, mask: CIImage, context: CIContext,
                               peak: Double, linear: CGColorSpace, srgb: CGColorSpace) throws -> CIImage {
            let extent = image.extent
            let width = Int(extent.width), height = Int(extent.height)
            let pixelCount = width.multipliedReportingOverflow(by: height)
            guard width > 0, height > 0, CGFloat(width) == extent.width, CGFloat(height) == extent.height,
                  !pixelCount.overflow, pixelCount.partialValue <= 8_000_000 else {
                throw RetouchAIError.invalidImage
            }
            var maskPixels = [UInt8](repeating: 0, count: pixelCount.partialValue)
            guard let gray = CGColorSpace(name: CGColorSpace.linearGray) else { throw RetouchAIError.invalidImage }
            context.render(mask.cropped(to: extent), toBitmap: &maskPixels, rowBytes: width,
                           bounds: extent, format: .R8, colorSpace: gray)
            var minX = width, maxX = -1, minY = height, maxY = -1
            for y in 0..<height {
                if y.isMultiple(of: 64) { try Task.checkCancellation() }
                for x in 0..<width where maskPixels[y * width + x] > 0 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return image }

            let maskMinX = extent.minX + CGFloat(minX), maskMaxX = extent.minX + CGFloat(maxX + 1)
            let maskMinY = extent.maxY - CGFloat(maxY + 1), maskMaxY = extent.maxY - CGFloat(minY)
            let tileSide: CGFloat = 800, coreSide: CGFloat = 672, stride: CGFloat = 640
            func origins(covering minimum: CGFloat, maximum: CGFloat) -> [CGFloat] {
                var values: [CGFloat] = []
                var origin = floor(minimum) - (tileSide - coreSide) / 2
                while true {
                    values.append(origin)
                    if origin + (tileSide + coreSide) / 2 >= maximum { break }
                    origin += stride
                }
                return values
            }
            let xOrigins = origins(covering: maskMinX, maximum: maskMaxX)
            let yOrigins = origins(covering: maskMinY, maximum: maskMaxY)
            var sums = [Float](repeating: 0, count: pixelCount.partialValue * 4)
            var weights = [Float](repeating: 0, count: pixelCount.partialValue)
            let coreInset = Int((tileSide - coreSide) / 2)
            let coreEnd = Int((tileSide + coreSide) / 2)

            for (yIndex, yOrigin) in yOrigins.enumerated() {
                // yOrigins rise in Core Image coordinates, while tile bitmap rows run top to bottom.
                let yWeights = RetouchAIModel.tileAxisBlendWeights(tileIndex: yIndex, tileCount: yOrigins.count,
                                                                   reverseOrder: true)
                for (xIndex, xOrigin) in xOrigins.enumerated() {
                    try Task.checkCancellation()
                    let window = CGRect(x: xOrigin, y: yOrigin, width: tileSide, height: tileSide)
                    let xOffset = Int(window.minX - extent.minX)
                    let yOffset = Int(extent.maxY - window.maxY)
                    let xWeights = RetouchAIModel.tileAxisBlendWeights(tileIndex: xIndex, tileCount: xOrigins.count)
                    var containsMask = false
                    for tileY in coreInset..<coreEnd where !containsMask {
                        let outputY = tileY + yOffset
                        guard outputY >= 0, outputY < height else { continue }
                        for tileX in coreInset..<coreEnd {
                            let outputX = tileX + xOffset
                            guard outputX >= 0, outputX < width else { continue }
                            if maskPixels[outputY * width + outputX] > 0 {
                                containsMask = true
                                break
                            }
                        }
                    }
                    guard containsMask else { continue }
                    let tile = try predictTile(image: image, mask: mask, extent: extent, window: window,
                                               context: context, peak: peak, linear: linear, srgb: srgb)
                    for tileY in coreInset..<coreEnd {
                        let outputY = tileY + yOffset
                        guard outputY >= 0, outputY < height else { continue }
                        for tileX in coreInset..<coreEnd {
                            let outputX = tileX + xOffset
                            guard outputX >= 0, outputX < width else { continue }
                            let pixel = outputY * width + outputX
                            guard maskPixels[pixel] > 0 else { continue }
                            let source = (tileY * 800 + tileX) * 4
                            let destination = pixel * 4
                            let weight = xWeights[tileX] * yWeights[tileY]
                            for channel in 0..<4 {
                                sums[destination + channel] += tile[source + channel] * weight
                            }
                            weights[pixel] += weight
                        }
                    }
                }
            }

            for index in 0..<pixelCount.partialValue where maskPixels[index] > 0 {
                try Task.checkCancellation()
                guard weights[index] > 0 else { throw RetouchAIError.invalidImage }
                let weight = weights[index], offset = index * 4
                for channel in 0..<3 { sums[offset + channel] /= weight }
                sums[offset + 3] = 1
            }
            let data = sums.withUnsafeBytes { Data($0) }
            return CIImage(bitmapData: data, bytesPerRow: width * 16,
                           size: CGSize(width: width, height: height), format: .RGBAf,
                           colorSpace: linear)
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
                .cropped(to: extent)
        }

        private func predictTile(image: CIImage, mask: CIImage, extent: CGRect, window: CGRect,
                                 context: CIContext, peak: Double,
                                 linear: CGColorSpace, srgb: CGColorSpace) throws -> [Float] {
            let bounds = CGRect(x: 0, y: 0, width: 800, height: 800)
            let transform = CGAffineTransform(translationX: -window.minX, y: -window.minY)
            let normalized = Self.exposure(image.clampedToExtent(), gain: 1 / peak)
                .cropped(to: window).transformed(by: transform)
            let black = CIImage(color: .black).cropped(to: window)
            let paddedMask = mask.cropped(to: extent).composited(over: black).cropped(to: window)
                .transformed(by: transform)
            let imageBuffer = try Self.buffer(format: kCVPixelFormatType_32BGRA)
            let maskBuffer = try Self.buffer(format: kCVPixelFormatType_OneComponent8)
            context.render(normalized, to: imageBuffer, bounds: bounds, colorSpace: srgb)
            context.render(paddedMask, to: maskBuffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceGray())
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(pixelBuffer: imageBuffer),
                "mask": MLFeatureValue(pixelBuffer: maskBuffer),
            ])
            let prediction = try model.prediction(from: provider)
            try Task.checkCancellation()
            guard let output = prediction.featureValue(for: "output")?.imageBufferValue else {
                throw RetouchAIError.invalidModel
            }
            let restored = Self.exposure(
                CIImage(cvPixelBuffer: output, options: [.colorSpace: srgb])
                    .transformed(by: transform.inverted()).cropped(to: window),
                gain: peak
            )
            var pixels = [Float](repeating: 0, count: 800 * 800 * 4)
            context.render(restored, toBitmap: &pixels, rowBytes: 800 * 16,
                           bounds: window, format: .RGBAf, colorSpace: linear)
            return pixels
        }

        private static func exposurePeak(_ image: CIImage, extent: CGRect,
                                         context: CIContext, colorSpace: CGColorSpace) -> Float {
            var samples = [Float](repeating: 0, count: 32 * 32 * 4)
            let sample = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                .concatenating(CGAffineTransform(scaleX: 32 / extent.width, y: 32 / extent.height)))
            context.render(sample, toBitmap: &samples, rowBytes: 32 * 16,
                           bounds: CGRect(x: 0, y: 0, width: 32, height: 32), format: .RGBAf,
                           colorSpace: colorSpace)
            return max(1, samples.enumerated().filter { $0.offset % 4 != 3 && $0.element.isFinite }
                .map(\.element).max() ?? 1)
        }

        private static func exposure(_ image: CIImage, gain: Double) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            ])
        }

        private static func buffer(format: OSType) throws -> CVPixelBuffer {
            var result: CVPixelBuffer?
            let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            guard CVPixelBufferCreate(kCFAllocatorDefault, 800, 800, format, attrs, &result) == kCVReturnSuccess,
                  let result else { throw RetouchAIError.invalidImage }
            return result
        }
    }
}

/// 每次下載有自己的 session；取消傳到網路 task，下載暫存只由這次安裝持有。
private final class ModelAssetDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var failure: Error?
    private var cancelled = false

    init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func fetch(url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let download = ModelAssetDownload(destination: destination, progress: progress)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                download.lock.withLock {
                    if download.cancelled { continuation.resume(throwing: CancellationError()); return }
                    download.continuation = continuation
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = 60
                    configuration.timeoutIntervalForResource = 1800
                    let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
                    download.session = session
                    let task = session.downloadTask(with: url)
                    download.task = task
                    task.resume()
                }
            }
        } onCancel: {
            download.lock.withLock { download.cancelled = true; download.task?.cancel() }
        }
        try Task.checkCancellation()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw RetouchAIError.http((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { lock.withLock { failure = error } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock {
            let completion = continuation
            continuation = nil
            if cancelled { completion?.resume(throwing: CancellationError()) }
            else if let error = error ?? failure { completion?.resume(throwing: error) }
            else { completion?.resume() }
            self.task = nil
            self.session = nil
        }
        session.finishTasksAndInvalidate()
    }
}
