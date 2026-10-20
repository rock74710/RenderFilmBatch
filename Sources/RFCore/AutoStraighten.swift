import Foundation
import CoreImage
import Vision

/// 自動水平：用 Vision 偵測地平線角度，旋轉後裁到不露黑邊的最大同比例矩形。
public enum AutoStraighten {
    /// 超過這個角度多半是誤判（或刻意斜拍），不套用。
    public static let maxDegrees = 10.0
    /// 小於這個角度視為已水平，不旋轉也不裁切。
    public static let minDegrees = 0.1

    /// 回傳要套用的修正角度（度，逆時針為正）；沒有可信的地平線時回傳 nil。
    public static func detect(_ image: CIImage, context: CIContext) -> Double? {
        // Vision 只需要小圖；先縮圖並產生 CGImage，避免在全解析度 RAW 上跑。
        let extent = image.extent
        let longest = max(extent.width, extent.height)
        guard longest > 0 else { return nil }
        let scale = min(1, 1024 / longest)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale),
                                      highQualityDownsample: true)
        guard let cgImage = context.createCGImage(small, from: small.extent, format: .RGBA8,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            return nil
        }
        let request = VNDetectHorizonRequest()
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        // Vision 的角度以左上為原點量測，數值正好就是 Core Image（左下原點）要旋轉的量。
        guard let horizon = request.results?.first,
              let degrees = accepted(horizon.angle * 180 / .pi) else { return nil }
        // Vision 的信心值恆為 1，沒有地平線的街景也會把電線、屋簷當成地平線；用畫面裡的直線再確認一次。
        return linesConfirm(degrees, in: image, context: context) ? degrees : nil
    }

    /// 畫面裡的直線（水平與垂直都算）是否支持旋轉 `degrees`：±10° 內邊緣最多的方向要在 `degrees` 的 1° 內。
    /// 地平線、建築線條會在歪斜的角度形成高峰；照片本來就正時，高峰在 0°。
    static func linesConfirm(_ degrees: Double, in image: CIImage, context: CIContext) -> Bool {
        let longest = max(image.extent.width, image.extent.height)
        guard longest > 0, let gamma = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) else { return false }
        let scale = min(1, 1024 / longest)
        // 先模糊再用一般縮放：Lanczos 縮圖和銳利斜邊的鋸齒都會讓逐像素的方向散開。
        // 邊緣延伸出去，外框才不會變成假的水平／垂直線。
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: 1.5 / scale)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = image.extent.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 2, height > 2 else { return false }
        var gray = [Float](repeating: 0, count: width * height)
        context.render(blurred, toBitmap: &gray, rowBytes: width * 4, bounds: bounds, format: .Lf, colorSpace: gamma)
        // 以 0.1° 為一格累計邊緣強度。記憶體第一列是畫面頂端（y 向下），這個座標下線條的斜角正好等於要旋轉的量。
        var histogram = [Double](repeating: 0, count: 900)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                func p(_ dx: Int, _ dy: Int) -> Double { Double(gray[(y + dy) * width + x + dx]) }
                let gx = p(1, -1) + 2 * p(1, 0) + p(1, 1) - p(-1, -1) - 2 * p(-1, 0) - p(-1, 1)
                let gy = p(-1, 1) + 2 * p(0, 1) + p(1, 1) - p(-1, -1) - 2 * p(0, -1) - p(1, -1)
                let magnitude = (gx * gx + gy * gy).squareRoot()
                guard magnitude > 0.1 else { continue }
                // 線的方向和梯度垂直；水平線與垂直線一起算，折到 ±45°。
                var angle = atan2(gy, gx) * 180 / .pi + 90
                angle -= 90 * (angle / 90).rounded()
                histogram[min(899, Int((angle + 45) * 10))] += magnitude
            }
        }
        /// 角度 ±1° 內的邊緣強度。
        func support(_ center: Double) -> Double {
            let low = max(0, Int(((center + 44) * 10).rounded())), high = min(899, Int(((center + 46) * 10).rounded()))
            return histogram[low...high].reduce(0, +)
        }
        let peak = stride(from: -maxDegrees, through: maxDegrees, by: 0.25).max { support($0) < support($1) } ?? 0
        return abs(peak - degrees) <= 1
    }

    /// 只接受 `minDegrees`–`maxDegrees` 之間的修正角度；超過 10° 不修正。
    static func accepted(_ degrees: Double) -> Double? {
        abs(degrees) >= minDegrees && abs(degrees) <= maxDegrees ? degrees : nil
    }

    /// 以中心旋轉 `degrees`，再裁成原比例、完全落在畫面內的最大矩形。
    public static func apply(_ degrees: Double, to image: CIImage) -> CIImage {
        guard degrees != 0 else { return image }
        let extent = image.extent
        let radians = degrees * .pi / 180
        let rotated = image.transformed(by: CGAffineTransform(translationX: extent.midX, y: extent.midY)
            .rotated(by: radians)
            .translatedBy(x: -extent.midX, y: -extent.midY))
        let factor = cropScale(size: extent.size, radians: radians)
        let width = (extent.width * factor).rounded(.down)
        let height = (extent.height * factor).rounded(.down)
        let crop = CGRect(x: (extent.midX - width / 2).rounded(), y: (extent.midY - height / 2).rounded(),
                          width: width, height: height)
        // 下游（縮放、輸出尺寸）預期原點在 0。
        return rotated.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    /// 旋轉後仍完全在原畫面內的同比例矩形，相對原尺寸的縮放倍率。
    static func cropScale(size: CGSize, radians: Double) -> Double {
        let c = abs(cos(radians)), s = abs(sin(radians))
        let w = Double(size.width), h = Double(size.height)
        return min(w / (w * c + h * s), h / (w * s + h * c))
    }
}
