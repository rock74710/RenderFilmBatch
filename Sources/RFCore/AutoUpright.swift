import Foundation
import CoreImage

/// 自動變形只採用夠長且彼此分開的直線；線索不足時保留原圖。
public enum AutoUpright {
    public struct Analysis: Equatable, Sendable {
        public let correction: GeometryParameters.UprightCorrection?
        public let message: String

        public init(correction: GeometryParameters.UprightCorrection?, message: String) {
            self.correction = correction
            self.message = message
        }
    }

    /// 先找兩條可信的近垂直邊緣並用引導線解算；找不到時再採用可信水平線。
    public static func analyze(_ image: CIImage, context: CIContext) -> Analysis {
        if let pair = VerticalLineDetector.detect(in: image, context: context),
           let correction = GeometryParameters.guidedCorrection(pair, extent: image.extent) {
            return Analysis(correction: correction, message: String(localized: "已依照片中的垂直邊緣自動校正。", bundle: .module))
        }
        if let rotation = AutoStraighten.detect(image, context: context) {
            return Analysis(correction: .init(rotation: rotation, verticalPerspective: 0),
                            message: String(localized: "已依照片中的水平線自動校正。", bundle: .module))
        }
        return Analysis(correction: nil, message: String(localized: "找不到可靠的垂直邊緣或水平線，照片維持原狀。", bundle: .module))
    }
}

private enum VerticalLineDetector {
    private struct Candidate {
        let slope: Double
        let intercept: Double
        let strength: Double

        var centerX: Double { intercept }

        func guide() -> GeometryParameters.GuideLine? {
            // 只使用畫面中間 80% 的線段，避免端點延伸到影像外。
            let top = intercept - slope * 0.4
            let bottom = intercept + slope * 0.4
            guard (0...1).contains(top), (0...1).contains(bottom) else { return nil }
            return GeometryParameters.GuideLine(
                start: .init(x: top, y: 0.9), end: .init(x: bottom, y: 0.1)
            )
        }
    }

    /// Hough 投票把長垂直邊緣連成線；方向與長度門檻會排除多數屋頂和細小窗框。
    static func detect(in image: CIImage, context: CIContext) -> [GeometryParameters.GuideLine]? {
        let extent = image.extent
        guard extent.width >= 64, extent.height >= 64,
              extent.width.isFinite, extent.height.isFinite else { return nil }
        let scale = min(1, 640 / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = small.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width >= 64, height >= 64 else { return nil }

        var rgba = [Float](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBufferPointer { pixels in
            guard let base = pixels.baseAddress else { return }
            context.render(small, toBitmap: base, rowBytes: width * 4 * MemoryLayout<Float>.size,
                           bounds: bounds, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        var luminance = [Float](repeating: 0, count: width * height)
        for index in luminance.indices {
            let offset = index * 4
            luminance[index] = 0.2126 * rgba[offset] + 0.7152 * rgba[offset + 1] + 0.0722 * rgba[offset + 2]
        }
        let ordered = luminance.sorted()
        guard var low = ordered.dropFirst(ordered.count / 20).first,
              var high = ordered.dropFirst(ordered.count * 19 / 20).first else { return nil }
        if high - low <= 0.02 {
            low = ordered.first ?? low
            high = ordered.last ?? high
        }
        guard high - low > 0.02 else { return nil }

        let slopes = stride(from: -0.4, through: 0.4, by: 0.01).map { $0 }
        let interceptBins = 512
        let interceptMinimum = -0.2
        let interceptSpan = 1.4
        var accumulator = [Float](repeating: 0, count: slopes.count * interceptBins)
        func value(_ x: Int, _ y: Int) -> Float {
            let normalized = (luminance[y * width + x] - low) / (high - low)
            return min(max(normalized, 0), 1)
        }
        for y in stride(from: 2, to: height - 2, by: 2) {
            let yNorm = (Double(y) + 0.5) / Double(height) - 0.5
            for x in stride(from: 2, to: width - 2, by: 2) {
                let gx = abs(value(x + 1, y) - value(x - 1, y))
                let gy = abs(value(x, y + 1) - value(x, y - 1))
                guard gx > 0.12, gx > gy * 1.4 else { continue }
                let xNorm = (Double(x) + 0.5) / Double(width)
                for (slopeIndex, slope) in slopes.enumerated() {
                    let intercept = xNorm - slope * yNorm
                    let bin = Int(((intercept - interceptMinimum) / interceptSpan * Double(interceptBins)).rounded())
                    if (0..<interceptBins).contains(bin) {
                        accumulator[slopeIndex * interceptBins + bin] += gx
                    }
                }
            }
        }

        let threshold = Float(height) * 0.16
        var peaks: [Candidate] = []
        for slopeIndex in 2..<(slopes.count - 2) {
            for bin in 2..<(interceptBins - 2) {
                let strength = accumulator[slopeIndex * interceptBins + bin]
                guard strength >= threshold else { continue }
                var maximum = true
                for ds in -2...2 where maximum {
                    for db in -3...3 where maximum {
                        if ds == 0 && db == 0 { continue }
                        let neighbor = accumulator[(slopeIndex + ds) * interceptBins + bin + db]
                        if neighbor > strength { maximum = false }
                    }
                }
                guard maximum else { continue }
                let intercept = interceptMinimum
                    + Double(bin) / Double(interceptBins) * interceptSpan
                let candidate = Candidate(slope: slopes[slopeIndex], intercept: intercept,
                                          strength: Double(strength))
                if candidate.guide() != nil {
                    peaks.append(candidate)
                }
            }
        }
        peaks.sort { $0.strength > $1.strength }
        var unique: [Candidate] = []
        for peak in peaks {
            guard !unique.contains(where: {
                abs($0.slope - peak.slope) < 0.025 && abs($0.intercept - peak.intercept) < 0.05
            }) else { continue }
            unique.append(peak)
            if unique.count == 24 { break }
        }

        var best: (score: Double, lines: [GeometryParameters.GuideLine])?
        for i in unique.indices {
            for j in unique.indices where j > i {
                let a = unique[i], b = unique[j]
                let separation = abs(a.centerX - b.centerX)
                guard separation >= 0.18,
                      let first = a.guide(), let second = b.guide() else { continue }
                let guides = [first, second].sorted {
                    ($0.start.x + $0.end.x) < ($1.start.x + $1.end.x)
                }
                guard GeometryParameters.guidedCorrection(guides, extent: extent) != nil else { continue }
                let score = a.strength + b.strength + separation * Double(height) * 0.08
                if best == nil || score > best!.score { best = (score, guides) }
            }
        }
        return best?.lines
    }
}
