import Foundation
import CoreImage
import CoreML
import Vision

/// 人物部位遮罩：Vision 分出每個人與五官，MediaPipe 多類別模型（Apache 2.0）分皮膚、頭髮、衣服。
///
/// 只產生選區；結果交給既有筆刷遮罩，局部調整仍走原本的遮罩渲染路徑。
public enum PersonParts {
    public enum Part: String, CaseIterable, Sendable {
        case faceSkin, bodySkin, hair, clothes, eyebrows, eyes, lips

        public var displayName: String {
            switch self {
            case .faceSkin: return String(localized: "AI 臉部皮膚", bundle: .module)
            case .bodySkin: return String(localized: "AI 身體皮膚", bundle: .module)
            case .hair: return String(localized: "AI 頭髮", bundle: .module)
            case .clothes: return String(localized: "AI 衣服", bundle: .module)
            case .eyebrows: return String(localized: "AI 眉毛", bundle: .module)
            case .eyes: return String(localized: "AI 眼睛", bundle: .module)
            case .lips: return String(localized: "AI 嘴唇", bundle: .module)
            }
        }

        /// selfie_multiclass 的輸出通道：0 背景、1 頭髮、2 身體皮膚、3 臉部皮膚、4 衣服、5 其他。
        var modelClass: Int? {
            switch self {
            case .hair: return 1
            case .bodySkin: return 2
            case .faceSkin: return 3
            case .clothes: return 4
            case .eyebrows, .eyes, .lips: return nil
            }
        }
    }

    public enum Failure: LocalizedError {
        case noPerson, noSelection, model(String)
        public var errorDescription: String? {
            switch self {
            case .noPerson: return String(localized: "沒有辨識到人物，請改用筆刷。", bundle: .module)
            case .noSelection: return String(localized: "這個人物沒有辨識到所選部位，請改用筆刷。", bundle: .module)
            case .model(let reason): return String(localized: "人物部位模型無法使用：\(reason)", bundle: .module)
            }
        }
    }

    /// 8-bit 單通道影像，第 0 列是影像最上方。
    public struct Raster: Sendable {
        public let width: Int
        public let height: Int
        public var pixels: [UInt8]

        public init(width: Int, height: Int, pixels: [UInt8]) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        var isEmpty: Bool { !pixels.contains { $0 > 2 } }
    }

    /// 一個人物：外框為左下原點像素座標，遮罩與分析影像同尺寸。
    public struct Person: Sendable {
        public let bounds: CGRect
        let mask: Raster
        let selectionGeneration: SelectionGeneration?
        let identity: UUID

        init(bounds: CGRect, mask: Raster) {
            self.bounds = bounds
            self.mask = mask
            self.selectionGeneration = nil
            self.identity = UUID()
        }

        init(bounds: CGRect, mask: Raster, selectionGeneration: SelectionGeneration,
             identity: UUID = UUID()) {
            self.bounds = bounds
            self.mask = mask
            self.selectionGeneration = selectionGeneration
            self.identity = identity
        }
    }

    /// One bounded, invocation-scoped context shared by people from one selection image.
    /// A weak identity check prevents stale hits without retaining the rendered source graph.
    final class SelectionGeneration: @unchecked Sendable {
        private struct RegionKey: Hashable {
            let x: UInt64
            let y: UInt64
            let width: UInt64
            let height: UInt64

            init(_ rect: CGRect) {
                x = Double(rect.origin.x).bitPattern
                y = Double(rect.origin.y).bitPattern
                width = Double(rect.width).bitPattern
                height = Double(rect.height).bitPattern
            }
        }

        private struct SegmentationKey: Hashable {
            let personIdentity: UUID
            let region: RegionKey
            let modelClass: Int
        }

        private struct SegmentationEntry {
            let key: SegmentationKey
            let raster: Raster
            let byteCount: Int
        }

        static let defaultRasterBudget = 64 * 1024 * 1024
        private static let segmentationEntryLimit = 128

        private let image: WeakCIImageReference
        private let rasterBudget: Int
        private let condition = NSCondition()
        private var cachedFaces: [FaceRegions]?
        private var facesInFlight = false
        private var segmentationEntries: [SegmentationEntry] = []
        private var segmentationInFlight: Set<SegmentationKey> = []
        private var retainedRasterByteCount = 0

        init(image: CIImage, rasterBudget: Int = defaultRasterBudget) {
            self.image = WeakCIImageReference(image)
            self.rasterBudget = max(0, rasterBudget)
        }

        var segmentationEntryCount: Int {
            condition.lock()
            defer { condition.unlock() }
            return segmentationEntries.count
        }

        var retainedRasterBytes: Int {
            condition.lock()
            defer { condition.unlock() }
            return retainedRasterByteCount
        }

        func matches(_ candidate: CIImage) -> Bool { image.value === candidate }

        func faceRegions(for candidate: CIImage, compute: () -> [FaceRegions]) -> [FaceRegions] {
            guard matches(candidate) else { return compute() }
            condition.lock()
            while facesInFlight { condition.wait() }
            if let cachedFaces {
                condition.unlock()
                return cachedFaces
            }
            facesInFlight = true
            condition.unlock()

            let result = compute()

            condition.lock()
            if !result.isEmpty { cachedFaces = result }
            facesInFlight = false
            condition.broadcast()
            condition.unlock()
            return result
        }

        func classMask(
            for candidate: CIImage,
            personIdentity: UUID,
            modelClass: Int,
            region: CGRect,
            compute: () throws -> Raster
        ) throws -> Raster {
            guard matches(candidate) else { return try compute() }
            let key = SegmentationKey(personIdentity: personIdentity,
                                      region: RegionKey(region), modelClass: modelClass)

            condition.lock()
            while true {
                if let index = segmentationEntries.firstIndex(where: { $0.key == key }) {
                    let entry = segmentationEntries.remove(at: index)
                    segmentationEntries.append(entry)
                    condition.unlock()
                    return entry.raster
                }
                if !segmentationInFlight.contains(key) {
                    segmentationInFlight.insert(key)
                    condition.unlock()
                    break
                }
                condition.wait()
            }

            let raster: Raster
            do {
                raster = try compute()
            } catch {
                condition.lock()
                segmentationInFlight.remove(key)
                condition.broadcast()
                condition.unlock()
                throw error
            }

            condition.lock()
            if rasterBudget > 0, Self.validRaster(raster), !raster.isEmpty,
               raster.pixels.count <= rasterBudget {
                segmentationEntries.append(SegmentationEntry(key: key, raster: raster,
                                                             byteCount: raster.pixels.count))
                retainedRasterByteCount += raster.pixels.count
                while (retainedRasterByteCount > rasterBudget
                       || segmentationEntries.count > Self.segmentationEntryLimit), !segmentationEntries.isEmpty {
                    retainedRasterByteCount -= segmentationEntries.removeFirst().byteCount
                }
            }
            segmentationInFlight.remove(key)
            condition.broadcast()
            condition.unlock()
            return raster
        }

        private static func validRaster(_ raster: Raster) -> Bool {
            guard raster.width > 0, raster.height > 0,
                  raster.width <= Int.max / raster.height else { return false }
            return raster.pixels.count == raster.width * raster.height
        }
    }

    /// 分析影像中的人物，由左到右排序；選單的「人物 1、2…」照這個順序。
    public static func people(in image: CIImage, context: CIContext) throws -> [Person] {
        let request = VNGeneratePersonInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { return [] }
        let people = try observation.allInstances.compactMap { instance -> Person? in
            let buffer = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler)
            let mask = raster(VisionSceneIntelligence.refine(CIImage(cvPixelBuffer: buffer), guide: image), context: context)
            guard let bounds = bounds(of: mask) else { return nil }
            return Person(bounds: bounds, mask: mask)
        }
        let generation = SelectionGeneration(image: image)
        return ordered(people).map { person in
            Person(bounds: person.bounds, mask: person.mask,
                   selectionGeneration: generation, identity: person.identity)
        }
    }

    static func ordered(_ people: [Person]) -> [Person] {
        people.sorted { $0.bounds.minX < $1.bounds.minX }
    }

    /// 為選定人物產生部位遮罩，編碼成與 AI 主體相同的 PNG 選區。
    public static func generate(part: Part, people selected: [Person], image: CIImage,
                                context: CIContext) throws -> Data {
        guard !selected.isEmpty else { throw Failure.noPerson }
        let width = Int(image.extent.width), height = Int(image.extent.height)
        let generation = selected.first?.selectionGeneration
        let canReuse = generation.map { candidate in
            candidate.matches(image) && selected.allSatisfy { $0.selectionGeneration === candidate }
        } ?? false
        let faces: [FaceRegions]
        if canReuse, let generation {
            faces = generation.faceRegions(for: image) { faceRegions(in: image, context: context) }
        } else {
            faces = faceRegions(in: image, context: context)
        }
        var result = Raster(width: width, height: height, pixels: [UInt8](repeating: 0, count: width * height))
        for person in selected {
            try Task.checkCancellation()
            let own = faces.filter { contains(person.mask, point: $0.center) }
            let piece: Raster
            switch part {
            case .eyebrows: piece = compose(model: fill(own.flatMap(\.eyebrows), width: width, height: height),
                                            person: person.mask, subtract: [])
            case .eyes: piece = compose(model: fill(own.flatMap(\.eyes), width: width, height: height),
                                        person: person.mask, subtract: [])
            case .lips: piece = compose(model: fill(own.flatMap(\.lips), width: width, height: height),
                                        person: person.mask,
                                        subtract: [fill(own.flatMap(\.innerLips), width: width, height: height)])
            case .faceSkin, .bodySkin, .hair, .clothes:
                // 模型以半身自拍訓練；頭髮與臉部皮膚改看頭肩範圍，全身照才不會把深色衣服當成頭髮。
                let heads = own.map(\.headRegion)
                let region = (part == .hair || part == .faceSkin) && !heads.isEmpty
                    ? heads.dropFirst().reduce(heads[0]) { $0.union($1) } : person.bounds
                let modelClass = part.modelClass!
                let model: Raster
                if canReuse, let generation {
                    model = try generation.classMask(for: image, personIdentity: person.identity,
                                                     modelClass: modelClass, region: region) {
                        try PartSegmenter.shared().classMask(modelClass, region: region, image: image,
                                                             context: context)
                    }
                } else {
                    model = try PartSegmenter.shared().classMask(modelClass, region: region, image: image,
                                                                 context: context)
                }
                let features = part == .faceSkin
                    ? [fill(own.flatMap { $0.eyebrows + $0.eyes + $0.lips }, width: width, height: height)] : []
                piece = compose(model: model, person: person.mask, subtract: features)
            }
            for i in result.pixels.indices where piece.pixels[i] > result.pixels[i] {
                result.pixels[i] = piece.pixels[i]
            }
        }
        guard !result.isEmpty else { throw Failure.noSelection }
        let mask = CIImage(bitmapData: Data(result.pixels), bytesPerRow: width,
                           size: CGSize(width: width, height: height), format: .L8, colorSpace: nil)
        return try AIMaskSelection.encode(mask, context: context)
    }

    /// 部位 = 模型 ∩ 人物，再扣掉 `subtract`（例如臉部皮膚扣掉五官）。
    static func compose(model: Raster, person: Raster, subtract: [Raster]) -> Raster {
        var out = model
        for i in out.pixels.indices {
            var value = min(model.pixels[i], person.pixels[i])
            for other in subtract { value = min(value, 255 - other.pixels[i]) }
            out.pixels[i] = value
        }
        return out
    }

    /// `point` 為左下原點像素座標。
    static func contains(_ mask: Raster, point: CGPoint) -> Bool {
        let x = Int(point.x), row = mask.height - 1 - Int(point.y)
        guard x >= 0, x < mask.width, row >= 0, row < mask.height else { return false }
        return mask.pixels[row * mask.width + x] > 127
    }

    /// 把左下原點的多邊形填成遮罩。
    static func fill(_ polygons: [[CGPoint]], width: Int, height: Int) -> Raster {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let cg = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            cg.setFillColor(gray: 1, alpha: 1)
            for polygon in polygons where polygon.count >= 3 {
                cg.addLines(between: polygon)
                cg.closePath()
            }
            cg.fillPath()
        }
        return Raster(width: width, height: height, pixels: pixels)
    }

    // MARK: - Vision 五官

    struct FaceRegions {
        var center: CGPoint
        /// 以臉框放大的頭肩範圍，涵蓋長髮。
        var headRegion: CGRect
        var eyebrows: [[CGPoint]]
        var eyes: [[CGPoint]]
        var lips: [[CGPoint]]
        var innerLips: [[CGPoint]]
    }

    static func faceRegions(in image: CIImage, context: CIContext) -> [FaceRegions] {
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
        let size = image.extent.size
        return (request.results ?? []).compactMap { face in
            guard let landmarks = face.landmarks else { return nil }
            func points(_ region: VNFaceLandmarkRegion2D?) -> [[CGPoint]] {
                guard let p = region?.pointsInImage(imageSize: size), p.count >= 3 else { return [] }
                return [p]
            }
            let box = VNImageRectForNormalizedRect(face.boundingBox, Int(size.width), Int(size.height))
            let head = CGRect(x: box.midX - box.width * 1.75, y: box.maxY + box.height * 0.8 - box.height * 4,
                              width: box.width * 3.5, height: box.height * 4)
            return FaceRegions(center: CGPoint(x: box.midX, y: box.midY), headRegion: head,
                               eyebrows: points(landmarks.leftEyebrow) + points(landmarks.rightEyebrow),
                               eyes: points(landmarks.leftEye) + points(landmarks.rightEye),
                               lips: points(landmarks.outerLips), innerLips: points(landmarks.innerLips))
        }
    }

    // MARK: - 像素工具

    static func raster(_ image: CIImage, context: CIContext) -> Raster {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        var pixels = [UInt8](repeating: 0, count: width * height)
        context.render(image, toBitmap: &pixels, rowBytes: width, bounds: extent, format: .L8, colorSpace: nil)
        return Raster(width: width, height: height, pixels: pixels)
    }

    /// 非零像素外框，左下原點。
    static func bounds(of mask: Raster) -> CGRect? {
        var minX = mask.width, maxX = -1, minRow = mask.height, maxRow = -1
        for row in 0..<mask.height {
            for x in 0..<mask.width where mask.pixels[row * mask.width + x] > 127 {
                minX = min(minX, x); maxX = max(maxX, x); minRow = min(minRow, row); maxRow = max(maxRow, row)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: mask.height - 1 - maxRow, width: maxX - minX + 1, height: maxRow - minRow + 1)
    }
}
