import Foundation
import CoreImage

public enum RetouchMode: String, Codable, Sendable {
    case clone, heal, remove
}

/// 保存產生這筆像素的操作，幾何後的筆畫搭配當時的映射，避免改裁切後漂移。
public struct RetouchRecipe: Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var algorithmVersion: String = "source-heal-1"
    public var version: Int = 2
    public var mode: RetouchMode
    public var outputPoints: [MaskPoint]
    public var outputRadius: Double
    public var feather: Double
    public var opacity: Double
    public var source: MaskPoint?
    public var sourceCandidates: [MaskPoint]
    public var optical: OpticalParameters
    public var useAI: Bool

    public init(mode: RetouchMode, outputPoints: [MaskPoint], outputRadius: Double,
                feather: Double = 0.12, opacity: Double = 1, source: MaskPoint? = nil,
                sourceCandidates: [MaskPoint] = [], optical: OpticalParameters, useAI: Bool = false) {
        self.mode = mode
        self.algorithmVersion = mode == .remove
            ? (useAI ? RetouchAIModel.revision : "patchmatch-1") : "source-heal-1"
        self.outputPoints = outputPoints
        self.outputRadius = outputRadius
        self.feather = feather
        self.opacity = opacity
        self.source = source
        self.sourceCandidates = sourceCandidates
        self.optical = optical
        self.useAI = useAI
    }

    public var canEditSource: Bool { version == 2 && mode != .remove && !useAI }

    public func matchesOpticalBase(_ current: OpticalParameters) -> Bool {
        var captured = optical
        var next = current
        captured.geometry = GeometryParameters()
        next.geometry = GeometryParameters()
        return captured == next
    }

    public func brushMask(extent: CGRect) throws -> RetouchBrushMask {
        guard version == 2 else { throw RetouchError.invalidStroke }
        return try optical.geometry.inputBrushMask(forOutput: outputPoints, radius: outputRadius,
            extent: extent, featherOutside: mode != .clone, feather: feather, opacity: opacity)
    }

    /// 將同一筆畫投影到目前畫布；更改幾何不會更改保存的選區。
    public func displayedPoints(geometry: GeometryParameters, extent: CGRect) -> [MaskPoint] {
        outputPoints.compactMap { point in
            guard let input = optical.geometry.inputPoint(forOutput: point, extent: extent) else { return nil }
            return geometry.outputPoint(forInput: input, extent: extent)
        }
    }
}

public extension RetouchParameters {
    /// 光學基底改變時不把舊座標的可編輯結果貼到新基底。舊格式保留原有行為。
    func applicable(to optical: OpticalParameters) -> RetouchParameters {
        RetouchParameters(enabled: enabled, patches: patches.filter { patch in
            patch.recipe.map { $0.matchesOpticalBase(optical) } ?? true
        })
    }
}
