import Foundation

/// 每張照片的批次曝光資料。sidecar 與曲線 XML 分開，複製曲線不會連曝光一起複製。
public struct BatchExposureAdjustment: Codable, Equatable, Sendable {
    public static let compensationRange = -3.0...3.0
    public static let fileExtension = "rfexposure.json"

    /// 使用者在拉桿上加減的 EV，範圍固定為 ±3。
    public var compensationEV: Double
    /// 匹配時求出的絕對基準 EV；存在時優先於 auto 與 smooth 的結果。
    public var matchedExposureEV: Double?

    public init(compensationEV: Double = 0, matchedExposureEV: Double? = nil) {
        self.compensationEV = compensationEV
        self.matchedExposureEV = matchedExposureEV
    }

    public var isNeutral: Bool { compensationEV == 0 && matchedExposureEV == nil }
    public var isValid: Bool {
        compensationEV.isFinite && Self.compensationRange.contains(compensationEV)
            && (matchedExposureEV?.isFinite ?? true)
    }

    /// 求最終總 EV：matched override、明確傳入的逐張 EV、auto EV 或 0，再加使用者補償。
    /// 明確傳入的 `smoothedEV` 同時承接批次的平滑 EV 與既有 API 的單張曝光參數，優先於 auto 開關。
    /// 傳回 nil 表示 sidecar 或分析值無效；呼叫端應保留原照片設定。
    public func effectiveEV(automaticExposure: Bool, automaticEV: Double,
                            smoothedEV: Double? = nil) -> Double? {
        guard isValid, automaticEV.isFinite, smoothedEV?.isFinite ?? true else { return nil }
        let base: Double
        if let matchedExposureEV {
            base = matchedExposureEV
        } else if let smoothedEV {
            base = smoothedEV
        } else if automaticExposure {
            base = automaticEV
        } else {
            base = 0
        }
        let total = base + compensationEV
        return total.isFinite ? total : nil
    }

    /// 將匹配出的最終總 EV 存成絕對基準，保留原有手動補償供之後微調。
    public func withMatchedTotalEV(_ totalEV: Double) throws -> Self {
        guard totalEV.isFinite, compensationEV.isFinite,
              Self.compensationRange.contains(compensationEV) else {
            throw BatchExposureError.invalidValue
        }
        let base = totalEV - compensationEV
        guard base.isFinite else { throw BatchExposureError.invalidValue }
        return Self(compensationEV: compensationEV, matchedExposureEV: base)
    }

    public static func sidecarURL(forPhoto photo: URL) -> URL {
        photo.appendingPathExtension(fileExtension)
    }

    /// 沒有 sidecar 時採中性曝光；損壞或非有限值會丟錯，不會猜一個 EV 套到原圖。
    public static func load(forPhoto photo: URL) throws -> Self? {
        let url = sidecarURL(forPhoto: photo)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.isValid else { throw BatchExposureError.invalidValue }
        return value
    }

    /// 中性設定刪除 sidecar；有調整時以原子寫入，避免留下半份 JSON。
    public func save(forPhoto photo: URL) throws {
        guard isValid else { throw BatchExposureError.invalidValue }
        let url = Self.sidecarURL(forPhoto: photo)
        if isNeutral {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    private enum CodingKeys: String, CodingKey { case compensationEV, matchedExposureEV }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        compensationEV = try container.decodeIfPresent(Double.self, forKey: .compensationEV) ?? 0
        matchedExposureEV = try container.decodeIfPresent(Double.self, forKey: .matchedExposureEV)
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .compensationEV, in: container,
                                                    debugDescription: "Invalid batch exposure value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard isValid else { throw BatchExposureError.invalidValue }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(compensationEV, forKey: .compensationEV)
        try container.encodeIfPresent(matchedExposureEV, forKey: .matchedExposureEV)
    }
}

public enum BatchExposureError: Error, CustomStringConvertible, Sendable {
    case invalidValue

    public var description: String {
        switch self {
        case .invalidValue: String(localized: "曝光 sidecar 包含無效數值", bundle: .module)
        }
    }
}

public struct BatchExposureMatchTarget: Sendable {
    public let photo: URL
    public let settings: BatchExportSettings

    public init(photo: URL, settings: BatchExportSettings) {
        self.photo = photo
        self.settings = settings
    }
}

public struct BatchExposureMatchFileResult: Sendable {
    public let photo: URL
    public let isReference: Bool
    public let adjustment: BatchExposureAdjustment?
    public let search: BatchExposureMatching.Result?
    public let error: String?

    public init(photo: URL, isReference: Bool = false, adjustment: BatchExposureAdjustment?,
                search: BatchExposureMatching.Result?, error: String?) {
        self.photo = photo
        self.isReference = isReference
        self.adjustment = adjustment
        self.search = search
        self.error = error
    }
}

public struct BatchExposureMatchReport: Sendable {
    public let reference: URL
    public let referenceMeasurement: BatchExposureMatching.Measurement
    public let results: [BatchExposureMatchFileResult]
    /// HDR 輸入一律以與預覽相同的 SDR 成品作為亮度目標。
    public let usedSDRPreview: Bool

    public init(reference: URL, referenceMeasurement: BatchExposureMatching.Measurement,
                results: [BatchExposureMatchFileResult], usedSDRPreview: Bool) {
        self.reference = reference
        self.referenceMeasurement = referenceMeasurement
        self.results = results
        self.usedSDRPreview = usedSDRPreview
    }
}

/// 曝光比對使用的成品亮度量測與有界 EV 搜尋。
public enum BatchExposureMatching {
    public enum Limitation: String, Equatable, Sendable {
        case none
        case highlights
        case exposureRange
    }

    public struct Measurement: Equatable, Sendable {
        public var medianLuminance: Double
        public var highlight99Luminance: Double
        public var validPixelCount: Int
        /// 量測主體時成功建立的 saliency／subject／face 權重來源。
        public var meteringSources: [String]

        public init(medianLuminance: Double, highlight99Luminance: Double,
                    validPixelCount: Int, meteringSources: [String] = []) {
            self.medianLuminance = medianLuminance
            self.highlight99Luminance = highlight99Luminance
            self.validPixelCount = validPixelCount
            self.meteringSources = meteringSources
        }

        public var usedWholeImageFallback: Bool { meteringSources.isEmpty }
    }

    public struct Result: Equatable, Sendable {
        /// 最終總 EV，包含原本的使用者補償。
        public let totalEV: Double
        public let measurement: Measurement
        public let limitation: Limitation
    }

    public enum MatchError: Error, Equatable, Sendable {
        case invalidTarget
        case invalidMeasurement
        case noSamples
        case invalidSearchRange
    }

    /// 以最終成品量測值做有界二分搜尋。clip 候選不會被選作安全結果；若整個範圍都已 clip，
    /// 仍沿亮度搜尋方向找最接近目標的一點並回報限制，避免高光讓整張匹配無法使用。
    public static func search(
        targetLuminance: Double,
        exposureRange: ClosedRange<Double> = -6...6,
        iterations: Int = 14,
        highlightLimit: Double = 0.995,
        evaluate: (Double) async throws -> Measurement
    ) async throws -> Result {
        guard targetLuminance.isFinite, targetLuminance > 0 else { throw MatchError.invalidTarget }
        guard exposureRange.lowerBound.isFinite, exposureRange.upperBound.isFinite,
              exposureRange.lowerBound < exposureRange.upperBound,
              iterations > 0, highlightLimit.isFinite,
              highlightLimit > 0, highlightLimit <= 1 else { throw MatchError.invalidSearchRange }

        func measure(_ ev: Double) async throws -> Measurement? {
            try Task.checkCancellation()
            let value = try await evaluate(ev)
            guard value.highlight99Luminance.isFinite, value.highlight99Luminance >= 0 else {
                throw MatchError.invalidMeasurement
            }
            if value.validPixelCount == 0 || value.medianLuminance == 0 { return nil }
            guard value.medianLuminance.isFinite, value.medianLuminance > 0 else {
                throw MatchError.invalidMeasurement
            }
            return value
        }

        func distance(_ value: Measurement) -> Double {
            abs(log2(value.medianLuminance / targetLuminance))
        }

        let anchorEV = min(max(0, exposureRange.lowerBound), exposureRange.upperBound)
        var resolvedAnchorEV = anchorEV
        var anchor = try await measure(anchorEV)
        if anchor == nil {
            for distance in [0.5, 1.0, 2.0, 3.0, 4.5, 6.0] {
                let candidateEV = min(max(anchorEV + distance, exposureRange.lowerBound), exposureRange.upperBound)
                anchor = try await measure(candidateEV)
                if anchor != nil {
                    resolvedAnchorEV = candidateEV
                    break
                }
            }
        }
        guard let anchor else { throw MatchError.noSamples }
        var bestOverall = (ev: resolvedAnchorEV, measurement: anchor)
        var bestUnclipped: (ev: Double, measurement: Measurement)?
        if anchor.highlight99Luminance < highlightLimit {
            bestUnclipped = bestOverall
        } else {
            // If the reference candidate is already clipped, look down the exposure range for a
            // safe starting point before falling back to an all-clipped brightness search.
            for offset in [0.5, 1.0, 2.0, 3.0, 4.5, 6.0] {
                let candidateEV = max(exposureRange.lowerBound, resolvedAnchorEV - offset)
                guard candidateEV < resolvedAnchorEV,
                      let candidate = try await measure(candidateEV) else { continue }
                if distance(candidate) < distance(bestOverall.measurement) {
                    bestOverall = (candidateEV, candidate)
                }
                if candidate.highlight99Luminance < highlightLimit {
                    bestUnclipped = (candidateEV, candidate)
                    break
                }
            }
        }
        var lower: Double
        var upper: Double
        if anchor.highlight99Luminance >= highlightLimit, let bestUnclipped {
            if bestUnclipped.measurement.medianLuminance < targetLuminance {
                lower = bestUnclipped.ev
                upper = exposureRange.upperBound
            } else {
                lower = exposureRange.lowerBound
                upper = bestUnclipped.ev
            }
        } else {
            lower = anchor.medianLuminance < targetLuminance ? resolvedAnchorEV : exposureRange.lowerBound
            upper = anchor.medianLuminance < targetLuminance ? exposureRange.upperBound : resolvedAnchorEV
        }
        var encounteredClipping = anchor.highlight99Luminance >= highlightLimit

        for _ in 0..<iterations {
            let ev = (lower + upper) / 2
            guard let measurement = try await measure(ev) else {
                // 沒有可量亮度代表這一側已落入黑位；往較亮方向移動。
                lower = ev
                continue
            }
            if distance(measurement) < distance(bestOverall.measurement) {
                bestOverall = (ev, measurement)
            }
            let clipped = measurement.highlight99Luminance >= highlightLimit
            encounteredClipping = encounteredClipping || clipped
            if clipped {
                if bestUnclipped != nil {
                    // 已知有安全候選時，先找最亮的安全邊界；全域都 clip 才依 median 搜尋。
                    upper = ev
                } else if measurement.medianLuminance < targetLuminance {
                    lower = ev
                } else {
                    upper = ev
                }
            } else {
                if bestUnclipped == nil || distance(measurement) < distance(bestUnclipped!.measurement) {
                    bestUnclipped = (ev, measurement)
                }
                if measurement.medianLuminance < targetLuminance { lower = ev }
                else { upper = ev }
                if distance(measurement) <= 0.04 { break }
            }
        }

        let selected = bestUnclipped ?? bestOverall
        let residualEV = log2(targetLuminance / selected.measurement.medianLuminance)
        let limitation: Limitation
        if selected.measurement.highlight99Luminance >= highlightLimit
            || (residualEV > 0 && encounteredClipping) {
            limitation = .highlights
        } else if abs(residualEV) <= 0.04 {
            limitation = .none
        } else {
            limitation = .exposureRange
        }
        return Result(totalEV: selected.ev, measurement: selected.measurement, limitation: limitation)
    }
}
