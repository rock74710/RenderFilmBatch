import Foundation
import CoreImage
import Vision

/// 自動膚色與柔膚：Vision 找臉和五官 → 皮膚遮罩 → 只在遮罩內校正膚色、削掉中頻斑駁。
///
/// 不用生成式模型，實際改像素的只有增益與模糊，痣、毛孔和五官形狀不會被重畫。
public enum PortraitRetouch {
    public static let levels = 1...10
    /// 看起來自然的膚色色相（OKLCH，度）：標準色卡由淺到深的膚色都落在約 44°–57°。
    static let skinHueRange = 40.0...60.0
    /// 膚色彩度範圍（OKLCH C）：低於下限顯得灰敗，高於上限像曬傷或過紅。
    static let skinChromaRange = 0.04...0.10
    /// 單次最多轉動的色相，避免誤判時把臉整個染色。
    static let maxHueShift = 35.0
    /// 偵測用小圖上的臉寬下限（px）；更小的臉柔膚看不出差別。
    static let minFaceWidth: CGFloat = 40

    /// 偵測用小圖上的一張臉，座標為像素、左下原點（同 Vision 與 Core Image）。
    struct Face {
        var eyeMid: CGPoint
        var mouth: CGPoint
        var width: CGFloat
        /// 眼、眉、嘴的輪廓，不柔膚也不調色。
        var excluded: [[CGPoint]]
    }

    /// 一張照片的人像分析：偵測小圖上的皮膚遮罩。
    struct Analysis {
        /// 已羽化的單通道遮罩，extent 為偵測小圖的大小。
        let mask: CIImage
        /// 每張臉各自的已羽化遮罩與皮膚範圍（偵測小圖座標），逐臉量膚色用。
        let faces: [(mask: CIImage, bounds: CGRect)]
        /// 最大臉寬相對影像寬度的比例，柔膚半徑依此換算。
        let faceWidthRatio: Double

        /// 放大到 `extent` 的遮罩。
        func mask(fittedTo extent: CGRect) -> CIImage {
            ExposureMetering.fit(mask, to: extent)
        }

        /// 放大到 `extent` 的逐臉遮罩與範圍。
        func faces(fittedTo extent: CGRect) -> [(mask: CIImage, bounds: CGRect)] {
            let sx = extent.width / mask.extent.width, sy = extent.height / mask.extent.height
            return faces.map { face in
                (ExposureMetering.fit(face.mask, to: extent),
                 face.bounds.applying(CGAffineTransform(scaleX: sx, y: sy))
                     .offsetBy(dx: extent.minX, dy: extent.minY).integral)
            }
        }

        func faceWidth(in extent: CGRect) -> Double { faceWidthRatio * Double(extent.width) }
    }

    // MARK: - 偵測與遮罩

    /// 找臉並產生皮膚遮罩；沒有夠大的臉時回傳 nil。`exposureEV` 讓暗的 RAW 也偵測得到臉。
    static func analyze(_ image: CIImage, exposureEV: Double, context: CIContext) -> Analysis? {
        let extent = image.extent
        let longest = max(extent.width, extent.height)
        guard longest > 0, !extent.isInfinite else { return nil }
        let scale = min(1, 1024 / longest)
        var small = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true)
        if exposureEV != 0 {
            small = small.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposureEV])
        }
        let width = Int(ceil(extent.width * scale)), height = Int(ceil(extent.height * scale))
        guard let cgImage = context.createCGImage(small, from: CGRect(x: 0, y: 0, width: width, height: height),
                                                  format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)),
              let data = cgImage.dataProvider?.data as Data? else { return nil }

        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        let size = CGSize(width: width, height: height)
        let faces = (request.results ?? []).compactMap { face(from: $0, imageSize: size) }
            .sorted { $0.width > $1.width }
            .prefix(8)
        guard let largest = faces.first else { return nil }

        let sigma = Double(largest.width) * 0.03
        func feather(_ pixels: [UInt8]) -> CIImage {
            let raster = CIImage(bitmapData: Data(pixels), bytesPerRow: width, size: size, format: .L8, colorSpace: nil)
            return raster.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: raster.extent)
        }
        var combined = [UInt8](repeating: 0, count: width * height)
        var perFace: [(mask: CIImage, bounds: CGRect)] = []
        for face in faces {
            let hard = faceMask([face], width: width, height: height)
            let gated = skinGate(hard, rgba: data, bytesPerRow: cgImage.bytesPerRow, width: width, height: height)
            for i in combined.indices where gated[i] > combined[i] { combined[i] = gated[i] }
            // 皮膚像素的外框（左下原點），加上羽化寬度。
            var minX = width, maxX = -1, minRow = height, maxRow = -1
            for y in 0..<height {
                for x in 0..<width where gated[y * width + x] > 0 {
                    minX = min(minX, x); maxX = max(maxX, x); minRow = min(minRow, y); maxRow = max(maxRow, y)
                }
            }
            guard maxX >= 0 else { continue }
            let bounds = CGRect(x: minX, y: height - 1 - maxRow, width: maxX - minX + 1, height: maxRow - minRow + 1)
                .insetBy(dx: -3 * sigma, dy: -3 * sigma)
                .intersection(CGRect(origin: .zero, size: size))
            perFace.append((feather(gated), bounds))
        }
        return Analysis(mask: feather(combined), faces: perFace,
                        faceWidthRatio: Double(largest.width) / Double(width))
    }

    private static func face(from observation: VNFaceObservation, imageSize: CGSize) -> Face? {
        guard let landmarks = observation.landmarks,
              let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye,
              let lips = landmarks.outerLips else { return nil }
        let width = observation.boundingBox.width * imageSize.width
        guard width >= minFaceWidth else { return nil }
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            region?.pointsInImage(imageSize: imageSize) ?? []
        }
        func centroid(_ p: [CGPoint]) -> CGPoint {
            CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
        }
        let left = centroid(points(leftEye)), right = centroid(points(rightEye))
        let excluded = [points(leftEye), points(rightEye), points(landmarks.leftEyebrow),
                        points(landmarks.rightEyebrow), points(lips)].filter { $0.count >= 3 }
        return Face(eyeMid: CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2),
                    mouth: centroid(points(lips)), width: width, excluded: excluded)
    }

    /// 臉部橢圓減掉五官，回傳 8-bit 遮罩（第 0 列是影像最上方）。
    ///
    /// 臉的方向取「嘴 → 兩眼中點」；以眼嘴距離 d 估計下巴在嘴下 0.6d、髮際在眼上 1.1d。
    static func faceMask(_ faces: [Face], width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let cg = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            for face in faces {
                let dx = face.eyeMid.x - face.mouth.x, dy = face.eyeMid.y - face.mouth.y
                let d = hypot(dx, dy)
                guard d > 0 else { continue }
                let up = CGPoint(x: dx / d, y: dy / d)
                let center = CGPoint(x: face.eyeMid.x - up.x * 0.25 * d, y: face.eyeMid.y - up.y * 0.25 * d)
                let along = 1.35 * d, across = face.width * 0.475
                cg.saveGState()
                cg.translateBy(x: center.x, y: center.y)
                cg.rotate(by: atan2(up.y, up.x) - .pi / 2)
                cg.setFillColor(gray: 1, alpha: 1)
                cg.fillEllipse(in: CGRect(x: -across, y: -along, width: across * 2, height: along * 2))
                cg.restoreGState()

                cg.setFillColor(gray: 0, alpha: 1)
                cg.setStrokeColor(gray: 0, alpha: 1)
                cg.setLineWidth(face.width * 0.06)
                cg.setLineJoin(.round)
                for outline in face.excluded {
                    cg.addLines(between: outline)
                    cg.closePath()
                    cg.drawPath(using: .fillStroke)
                }
            }
        }
        return pixels
    }

    /// 只留下和這張臉膚色接近的像素，排除橢圓內的頭髮、背景和衣服。
    private static func skinGate(_ hard: [UInt8], rgba: Data, bytesPerRow: Int, width: Int, height: Int) -> [UInt8] {
        let decode = (0..<256).map { v -> Double in
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        var labs = [SIMD3<Double>](repeating: .zero, count: hard.count)
        var inside: [Int] = []
        rgba.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width where hard[y * width + x] > 127 {
                    let p = y * bytesPerRow + x * 4
                    let rgb = SIMD3(decode[Int(bytes[p])], decode[Int(bytes[p + 1])], decode[Int(bytes[p + 2])])
                    labs[y * width + x] = OKLab.fromXYZ(RGBColorSpace.sRGB.toXYZ(rgb))
                    inside.append(y * width + x)
                }
            }
        }
        guard inside.count >= 20 else { return [UInt8](repeating: 0, count: hard.count) }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let reference = SIMD3(median(inside.map { labs[$0].x }), median(inside.map { labs[$0].y }),
                              median(inside.map { labs[$0].z }))
        var out = [UInt8](repeating: 0, count: hard.count)
        for i in inside {
            let lab = labs[i]
            let colour = 1 - smoothstep(0.03, 0.06, hypot(lab.y - reference.y, lab.z - reference.z))
            let lightness = 1 - smoothstep(0.15, 0.3, abs(lab.x - reference.x))
            out[i] = UInt8((255 * colour * lightness).rounded())
        }
        return out
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - 膚色

    /// 遮罩內的平均膚色（working space 線性 RGB）；皮膚太少時回傳 nil。
    static func skinMean(_ image: CIImage, mask: CIImage, context: CIContext) -> SIMD3<Double>? {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return nil }
        let scale = min(1, 256 / max(extent.width, extent.height))
        let width = max(1, Int(ceil(extent.width * scale))), height = max(1, Int(ceil(extent.height * scale)))
        let pixels = AutoExposure.render(image, extent: extent, scale: scale, width: width, height: height,
                                         context: context)
        let weights = AutoExposure.render(mask, extent: extent, scale: scale, width: width, height: height,
                                          context: context, colorSpace: nil)
        var sum = SIMD3<Double>.zero, total = 0.0, count = 0
        for i in stride(from: 0, to: pixels.count, by: 4) where weights[i] > 0.5 {
            let w = Double(weights[i])
            sum += SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])) * w
            total += w
            count += 1
        }
        return count >= 20 ? sum / total : nil
    }

    /// 把膚色往自然範圍拉：亮度不變，只動色相與彩度；已在範圍內就不動。`level` 1–10 = 拉 10%–100%。
    static func targetLCH(_ lch: SIMD3<Double>, level: Int) -> SIMD3<Double> {
        let t = Double(min(max(level, 0), 10)) / 10
        let center = (skinHueRange.lowerBound + skinHueRange.upperBound) / 2
        let half = (skinHueRange.upperBound - skinHueRange.lowerBound) / 2
        var offset = (lch.z - center).truncatingRemainder(dividingBy: 360)
        if offset > 180 { offset -= 360 } else if offset < -180 { offset += 360 }
        let shift = min(max((min(max(offset, -half), half) - offset) * t, -maxHueShift), maxHueShift)
        var hue = center + offset + shift
        if hue < 0 { hue += 360 } else if hue >= 360 { hue -= 360 }
        let chroma = lch.y + (min(max(lch.y, skinChromaRange.lowerBound), skinChromaRange.upperBound) - lch.y) * t
        return SIMD3(lch.x, chroma, shift == 0 ? lch.z : hue)
    }

    /// 求一組套在 scene-linear 影像上的 RGB 增益，讓平均膚色經過 `transform`（白平衡、曝光）後落到目標。
    /// 不需要調整時回傳 nil。
    static func gains(skinMean: SIMD3<Double>, transform: SceneTransform, level: Int) -> SIMD3<Double>? {
        let working = RGBColorSpace.workingRec2020
        func lch(_ rgb: SIMD3<Double>) -> SIMD3<Double> { OKLab.toLCH(OKLab.fromXYZ(working.toXYZ(rgb))) }
        let current = lch(transform.apply(skinMean))
        // 幾乎沒有彩度（灰階、嚴重欠曝）時色相沒有意義。
        guard current.y > 0.01 else { return nil }
        let target = targetLCH(current, level: level)
        guard target != current else { return nil }
        let goal = working.fromXYZ(OKLab.toXYZ(OKLab.fromLCH(target)))
        guard goal.min() > 0 else { return nil }
        var g = SIMD3<Double>(1, 1, 1)
        // transform 接近逐通道縮放，用比例迭代幾次就收斂。
        for _ in 0..<8 {
            let out = transform.apply(skinMean * g)
            guard out.min() > 1e-6 else { return nil }
            g *= goal / out
        }
        return simd_clamp(g, SIMD3(repeating: 0.6), SIMD3(repeating: 1.6))
    }

    /// 每張臉各自量平均膚色、各自求增益再套用：合照裡每個人的偏色分開修正。
    static func correctTone(_ image: CIImage, faces: [(mask: CIImage, bounds: CGRect)],
                            transform: SceneTransform, level: Int, context: CIContext) -> CIImage {
        var result = image
        for face in faces {
            let region = face.bounds.intersection(image.extent)
            guard !region.isEmpty,
                  let skin = skinMean(image.cropped(to: region), mask: face.mask.cropped(to: region), context: context),
                  let g = gains(skinMean: skin, transform: transform, level: level) else { continue }
            result = applyGains(g, mask: face.mask, to: result)
        }
        return result
    }

    /// 只在遮罩內乘上增益，遮罩邊緣漸變。
    static func applyGains(_ g: SIMD3<Double>, mask: CIImage, to image: CIImage) -> CIImage {
        let corrected = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: g.x, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g.y, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: g.z, w: 0),
        ])
        return corrected.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask,
        ]).cropped(to: image.extent)
    }

    // MARK: - 柔膚

    /// 原圖 = 細紋理（原圖 − 細模糊）+ 中頻（細模糊 − 粗模糊）+ 低頻（粗模糊）。
    /// 只削中頻（斑點、泛紅不均），毛孔等細紋理保留；中頻或像素本身跟周圍對比強的地方視為五官不動。
    nonisolated(unsafe) private static let smoothKernel = CIColorKernel(source: """
    kernel vec4 skinSmooth(__sample src, __sample fine, __sample base, __sample mask, float amount) {
        vec3 luma = vec3(0.2627, 0.6780, 0.0593);
        float lf = dot(max(fine.rgb, vec3(0.0)), luma);
        float lb = max(dot(max(base.rgb, vec3(0.0)), luma), 1e-4);
        float ls = dot(max(src.rgb, vec3(0.0)), luma);
        float feature = max(smoothstep(0.3, 0.8, abs(lf - lb) / lb), smoothstep(0.25, 0.5, abs(ls - lb) / lb));
        float w = amount * clamp(mask.r, 0.0, 1.0) * (1.0 - feature);
        return vec4(src.rgb - w * (fine.rgb - base.rgb), src.a);
    }
    """)

    /// 跟周圍亮度差很多的像素（眼鏡框、鼻孔、反光）換成周圍平均，
    /// 兩層模糊才不會把它們抹進皮膚，造成亮邊或把細線抹淡。
    nonisolated(unsafe) private static let outlierKernel = CIColorKernel(source: """
    kernel vec4 skinOutliers(__sample src, __sample around) {
        vec3 luma = vec3(0.2627, 0.6780, 0.0593);
        float ls = dot(max(src.rgb, vec3(0.0)), luma);
        float la = max(dot(max(around.rgb, vec3(0.0)), luma), 1e-4);
        float outlier = smoothstep(0.25, 0.5, abs(ls - la) / la);
        return vec4(mix(src.rgb, around.rgb, outlier), src.a);
    }
    """)

    /// `faceWidth` 是目前影像上的臉寬（px），模糊半徑依此換算，預覽與輸出才一致。`level` 1–10。
    static func smooth(_ image: CIImage, mask: CIImage, faceWidth: Double, level: Int) -> CIImage {
        let amount = Double(min(max(level, 0), 10)) / 10
        guard amount > 0, faceWidth > 0, let kernel = smoothKernel, let outliers = outlierKernel else { return image }
        let fineSigma = max(0.5, faceWidth * 0.004), baseSigma = max(2, faceWidth * 0.03)
        let around = image.clampedToExtent().applyingGaussianBlur(sigma: baseSigma)
        guard let cleaned = outliers.apply(extent: image.extent, arguments: [image, around]) else { return image }
        let clamped = cleaned.clampedToExtent()
        let fine = clamped.applyingGaussianBlur(sigma: fineSigma)
        let base = clamped.applyingGaussianBlur(sigma: baseSigma)
        return kernel.apply(extent: image.extent, arguments: [image, fine, base, mask, amount]) ?? image
    }
}
