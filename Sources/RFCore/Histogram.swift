import Foundation

public enum HistogramMode: Sendable {
    case rgbExposure
    case lab
}

public struct HistogramChannels: Equatable, Sendable {
    public let channels: [[Double]]
    /// SDR reference white 在 x 軸上的位置（0…1）。SDR 直方圖為 nil，
    /// EDR 直方圖用它畫出「這條線以上屬於 headroom」的標記。
    public let sdrWhitePosition: Double?

    public init(channels: [[Double]], sdrWhitePosition: Double? = nil) {
        self.channels = channels
        self.sdrWhitePosition = sdrWhitePosition
    }
}

/// 由 8-bit sRGB RGBA 像素建立預覽直方圖。結果各通道都正規化到 0...1。
public enum HistogramCalculator {
    public static func calculate(
        rgba: [UInt8], width: Int, height: Int, bytesPerRow: Int,
        mode: HistogramMode, bins: Int = 128
    ) -> HistogramChannels {
        guard width > 0, height > 0, bins > 1,
              rgba.count >= bytesPerRow * height else {
            return HistogramChannels(channels: Array(repeating: Array(repeating: 0, count: max(bins, 0)), count: 4))
        }
        var counts = Array(repeating: Array(repeating: 0.0, count: bins), count: 4)
        let step = max(1, Int(sqrt(Double(width * height) / 160_000.0)))

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let i = y * bytesPerRow + x * 4
                let r = Double(rgba[i]) / 255
                let g = Double(rgba[i + 1]) / 255
                let b = Double(rgba[i + 2]) / 255
                if mode == .rgbExposure {
                    add(r, to: &counts[0], bins: bins)
                    add(g, to: &counts[1], bins: bins)
                    add(b, to: &counts[2], bins: bins)
                    add(0.2126 * r + 0.7152 * g + 0.0722 * b, to: &counts[3], bins: bins)
                } else {
                    let lab = cieLab(r: r, g: g, b: b)
                    add(lab.0 / 100, to: &counts[0], bins: bins)
                    add((lab.1 + 128) / 255, to: &counts[1], bins: bins)
                    add((lab.2 + 128) / 255, to: &counts[2], bins: bins)
                }
            }
        }
        for c in counts.indices {
            let peak = counts[c].max() ?? 0
            if peak > 0 { counts[c] = counts[c].map { $0 / peak } }
        }
        return HistogramChannels(channels: counts)
    }

    /// 由 extended-linear half-float 像素建立 EDR 直方圖。
    ///
    /// x 軸是「除以 headroom 後再做 sRGB 編碼」：陰影仍有足夠解析度，SDR white
    /// 以上的 headroom 也完整落在圖上，不會像 8-bit 取樣那樣全部堆在最右端。
    /// Lab 模式的色度定義只在 SDR 範圍內成立，所以先把亮度夾到 SDR white 再算。
    public static func calculateExtendedLinear(
        rgba: [Float], width: Int, height: Int, componentsPerRow: Int,
        mode: HistogramMode, headroom: Double, bins: Int = 128
    ) -> HistogramChannels {
        let headroom = max(headroom, 1.0)
        let empty = HistogramChannels(channels: Array(repeating: Array(repeating: 0, count: max(bins, 0)), count: 4))
        guard width > 0, height > 0, bins > 1,
              rgba.count >= componentsPerRow * height else { return empty }

        var counts = Array(repeating: Array(repeating: 0.0, count: bins), count: 4)
        let step = max(1, Int(sqrt(Double(width * height) / 160_000.0)))
        /// display-linear → 顯示用的 x 軸位置。
        func axis(_ v: Double) -> Double {
            TargetTransform.encodeSRGB(max(v, 0) / headroom)
        }

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let i = y * componentsPerRow + x * 4
                let r = Double(rgba[i]), g = Double(rgba[i + 1]), b = Double(rgba[i + 2])
                if mode == .rgbExposure {
                    add(axis(r), to: &counts[0], bins: bins)
                    add(axis(g), to: &counts[1], bins: bins)
                    add(axis(b), to: &counts[2], bins: bins)
                    add(axis(0.2126 * r + 0.7152 * g + 0.0722 * b), to: &counts[3], bins: bins)
                } else {
                    let lab = cieLab(r: TargetTransform.encodeSRGB(r),
                                     g: TargetTransform.encodeSRGB(g),
                                     b: TargetTransform.encodeSRGB(b))
                    add(lab.0 / 100, to: &counts[0], bins: bins)
                    add((lab.1 + 128) / 255, to: &counts[1], bins: bins)
                    add((lab.2 + 128) / 255, to: &counts[2], bins: bins)
                }
            }
        }
        for c in counts.indices {
            let peak = counts[c].max() ?? 0
            if peak > 0 { counts[c] = counts[c].map { $0 / peak } }
        }
        // Lab 模式已夾在 SDR 內，標記畫出來只會誤導。
        let marker = mode == .rgbExposure && headroom > 1 ? axis(1.0) : nil
        return HistogramChannels(channels: counts, sdrWhitePosition: marker)
    }

    private static func add(_ value: Double, to values: inout [Double], bins: Int) {
        let i = min(bins - 1, max(0, Int(value * Double(bins))))
        values[i] += 1
    }

    private static func cieLab(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        func linear(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = linear(r), g = linear(g), b = linear(b)
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ v: Double) -> Double {
            v > 0.008856 ? pow(v, 1.0 / 3.0) : 7.787 * v + 16.0 / 116.0
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}
