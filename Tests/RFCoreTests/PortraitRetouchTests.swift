import XCTest
import CoreImage
@testable import RFCore

final class PortraitRetouchTests: XCTestCase {
    func testPortraitParametersDefaultForOlderSidecarsAndHonorTheEnableToggle() throws {
        let encoded = try JSONEncoder().encode(EditParameters())
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "portraitRetouch")
        let decodedLegacy = try JSONDecoder().decode(
            EditParameters.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decodedLegacy.portraitRetouch, PortraitRetouchParameters())

        var configured = EditParameters()
        configured.portraitRetouch = PortraitRetouchParameters(enabled: true, skinToneLevel: 6, skinSmoothingLevel: 4)
        XCTAssertEqual(configured.effective.portraitRetouch, configured.portraitRetouch)
        configured.portraitRetouch.enabled = false
        XCTAssertEqual(configured.effective.portraitRetouch, PortraitRetouchParameters())
        configured.portraitRetouch.enabled = true
        configured.portraitRetouch.skinToneLevel = 99
        configured.portraitRetouch.skinSmoothingLevel = -1
        XCTAssertEqual(configured.effective.portraitRetouch.skinToneLevel, 10)
        XCTAssertEqual(configured.effective.portraitRetouch.skinSmoothingLevel, 0)
    }

    private let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!

    private func context() -> CIContext {
        CIContext(options: [.workingColorSpace: space, .workingFormat: NSNumber(value: CIFormat.RGBAf.rawValue)])
    }

    // MARK: - 皮膚遮罩

    /// 正臉：雙眼在上、嘴在下，臉寬 200 px。
    private func syntheticFace() -> PortraitRetouch.Face {
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> [CGPoint] {
            [CGPoint(x: x - w / 2, y: y - h / 2), CGPoint(x: x + w / 2, y: y - h / 2),
             CGPoint(x: x + w / 2, y: y + h / 2), CGPoint(x: x - w / 2, y: y + h / 2)]
        }
        return PortraitRetouch.Face(
            eyeMid: CGPoint(x: 200, y: 230), mouth: CGPoint(x: 200, y: 150), width: 200,
            excluded: [box(160, 230, 40, 16), box(240, 230, 40, 16), box(200, 150, 60, 20)])
    }

    func testFaceMaskCoversSkinButNotEyesOrMouth() {
        let mask = PortraitRetouch.faceMask([syntheticFace()], width: 400, height: 400)
        func value(_ x: Int, _ y: Int) -> UInt8 { mask[(399 - y) * 400 + x] } // 列 0 是影像最上方
        XCTAssertEqual(value(150, 190), 255, "臉頰")
        XCTAssertEqual(value(200, 300), 255, "額頭")
        XCTAssertEqual(value(160, 230), 0, "眼睛")
        XCTAssertEqual(value(200, 150), 0, "嘴")
        XCTAssertEqual(value(20, 20), 0, "臉外")
        XCTAssertEqual(value(380, 230), 0, "臉外")
    }

    // MARK: - 膚色

    func testToneTargetPullsCastIntoSkinRangeAndKeepsLightness() {
        let greenish = SIMD3(0.7, 0.07, 84.0)
        let full = PortraitRetouch.targetLCH(greenish, level: 10)
        XCTAssertEqual(full.x, 0.7, accuracy: 1e-12)
        XCTAssertEqual(full.z, PortraitRetouch.skinHueRange.upperBound, accuracy: 1e-9)
        let half = PortraitRetouch.targetLCH(greenish, level: 5)
        XCTAssertEqual(half.z, (84 + PortraitRetouch.skinHueRange.upperBound) / 2, accuracy: 1e-9)

        let magenta = PortraitRetouch.targetLCH(SIMD3(0.7, 0.07, 8), level: 10)
        XCTAssertEqual(magenta.z, PortraitRetouch.skinHueRange.lowerBound, accuracy: 1e-9)

        let saturated = PortraitRetouch.targetLCH(SIMD3(0.6, 0.16, 50), level: 10)
        XCTAssertEqual(saturated.y, PortraitRetouch.skinChromaRange.upperBound, accuracy: 1e-9)

        let natural = SIMD3(0.7, 0.07, 50.0)
        XCTAssertEqual(PortraitRetouch.targetLCH(natural, level: 10), natural, "正常膚色不動")
    }

    func testGainsMoveMeasuredSkinToTarget() throws {
        let transform = SceneTransform(layerA: LayerATechnical(), colorEngine: ColorEngineParameters())
        let working = RGBColorSpace.workingRec2020
        // 偏綠的膚色。
        let skin = working.fromXYZ(OKLab.toXYZ(OKLab.fromLCH(SIMD3(0.7, 0.07, 84))))
        let gains = try XCTUnwrap(PortraitRetouch.gains(skinMean: skin, transform: transform, level: 10))
        let corrected = OKLab.toLCH(OKLab.fromXYZ(working.toXYZ(transform.apply(skin * gains))))
        XCTAssertEqual(corrected.z, PortraitRetouch.skinHueRange.upperBound, accuracy: 1)
        XCTAssertEqual(corrected.x, 0.7, accuracy: 0.005)

        let natural = working.fromXYZ(OKLab.toXYZ(OKLab.fromLCH(SIMD3(0.7, 0.07, 50))))
        XCTAssertNil(PortraitRetouch.gains(skinMean: natural, transform: transform, level: 10),
                     "已在膚色範圍內就不調")
    }

    /// 合照裡兩個人偏色方向相反（一個偏綠、一個偏洋紅）：逐臉量、逐臉修正，兩個人都拉進膚色範圍。
    /// 合起來量的話兩人套同一組增益，偏色互相抵銷，各自的偏色都修不掉。
    func testToneCorrectsEachFaceSeparately() throws {
        let ctx = context()
        let transform = SceneTransform(layerA: LayerATechnical(), colorEngine: ColorEngineParameters())
        let working = RGBColorSpace.workingRec2020
        func rgb(_ hue: Double) -> SIMD3<Double> { working.fromXYZ(OKLab.toXYZ(OKLab.fromLCH(SIMD3(0.7, 0.07, hue)))) }
        func lch(_ rgb: SIMD3<Double>) -> SIMD3<Double> { OKLab.toLCH(OKLab.fromXYZ(working.toXYZ(transform.apply(rgb)))) }
        func solid(_ c: SIMD3<Double>, _ rect: CGRect) -> CIImage {
            CIImage(color: CIColor(red: c.x, green: c.y, blue: c.z, colorSpace: space)!).cropped(to: rect)
        }
        let left = CGRect(x: 0, y: 0, width: 200, height: 200), right = CGRect(x: 200, y: 0, width: 200, height: 200)
        let image = solid(rgb(84), left).composited(over: solid(rgb(8), right))
        let black = solid(.zero, CGRect(x: 0, y: 0, width: 400, height: 200))
        let faces = [left, right].map { (mask: solid(SIMD3(1, 1, 1), $0).composited(over: black), bounds: $0) }

        func hue(_ image: CIImage, _ rect: CGRect) throws -> Double {
            lch(try XCTUnwrap(PortraitRetouch.skinMean(image.cropped(to: rect), mask: solid(SIMD3(1, 1, 1), rect),
                                                       context: ctx))).z
        }
        let range = (PortraitRetouch.skinHueRange.lowerBound - 1)...(PortraitRetouch.skinHueRange.upperBound + 1)
        let corrected = PortraitRetouch.correctTone(image, faces: faces, transform: transform, level: 10, context: ctx)
        for rect in [left, right] {
            let h = try hue(corrected, rect)
            XCTAssertTrue(range.contains(h), "色相 \(h) 在 \(rect)")
        }

        let whole = CGRect(x: 0, y: 0, width: 400, height: 200)
        let together = PortraitRetouch.correctTone(image, faces: [(solid(SIMD3(1, 1, 1), whole), whole)],
                                                   transform: transform, level: 10, context: ctx)
        XCTAssertFalse(range.contains(try hue(together, left)), "合起來量時偏綠的人修不掉")
    }

    // MARK: - 柔膚

    /// 400×400：灰底 + 週期 40 px 的斑駁（中頻）+ 2 px 棋盤格（毛孔般的細紋理）。
    private func texturedImage() -> CIImage {
        let n = 400
        var pixels = [Float](repeating: 1, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let blotch = 0.03 * sin(Double(x) * 2 * .pi / 40) * sin(Double(y) * 2 * .pi / 40)
                let fine = (x + y) % 2 == 0 ? 0.01 : -0.01
                let v = Float(0.3 + blotch + fine)
                let i = (y * n + x) * 4
                pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v
            }
        }
        return CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: n * 16,
                       size: CGSize(width: n, height: n), format: .RGBAf, colorSpace: space)
    }

    private func render(_ image: CIImage, _ ctx: CIContext) -> [Float] {
        var out = [Float](repeating: 0, count: 400 * 400 * 4)
        out.withUnsafeMutableBytes {
            ctx.render(image, toBitmap: $0.baseAddress!, rowBytes: 400 * 16,
                       bounds: CGRect(x: 0, y: 0, width: 400, height: 400), format: .RGBAf, colorSpace: space)
        }
        return out
    }

    /// 在 [x0, x1) 範圍內量：4×4 區塊平均的標準差（斑駁）與相鄰像素差（細紋理）。
    private func measure(_ px: [Float], x0: Int, x1: Int) -> (blotch: Double, fine: Double) {
        var means: [Double] = [], diffs: [Double] = []
        for by in stride(from: 40, to: 360, by: 4) {
            for bx in stride(from: x0 + 20, to: x1 - 20, by: 4) {
                var sum = 0.0
                for y in by..<by + 4 { for x in bx..<bx + 4 { sum += Double(px[(y * 400 + x) * 4]) } }
                means.append(sum / 16)
                let i = (by * 400 + bx) * 4
                diffs.append(abs(Double(px[i]) - Double(px[i + 4])))
            }
        }
        let mean = means.reduce(0, +) / Double(means.count)
        let std = sqrt(means.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(means.count))
        return (std, diffs.reduce(0, +) / Double(diffs.count))
    }

    func testSmoothingFlattensBlotchesKeepsTextureAndStaysInsideMask() {
        let ctx = context()
        let image = texturedImage()
        let mask = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 400))
            .composited(over: CIImage(color: .black).cropped(to: image.extent))
        let out = render(PortraitRetouch.smooth(image, mask: mask, faceWidth: 400, level: 10), ctx)
        let before = render(image, ctx)

        let inside = measure(out, x0: 0, x1: 180), original = measure(before, x0: 0, x1: 180)
        XCTAssertLessThan(inside.blotch, original.blotch * 0.4, "中頻斑駁要明顯變淡")
        XCTAssertGreaterThan(inside.fine, original.fine * 0.7, "毛孔般的細紋理要保留")

        // 遮罩外完全不動（遮罩邊緣留 20 px 緩衝）。
        for y in stride(from: 0, to: 400, by: 7) {
            for x in stride(from: 240, to: 400, by: 7) {
                let i = (y * 400 + x) * 4
                XCTAssertEqual(out[i], before[i], accuracy: 1e-4)
            }
        }
    }

    /// 臉上的細黑線（眼鏡框、睫毛）旁邊不能出現亮邊，線本身也不能被抹淡。
    func testSmoothingLeavesNoHaloBesideThinDarkLines() {
        let ctx = context()
        let line = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05))
            .cropped(to: CGRect(x: 100, y: 0, width: 3, height: 400))
        let image = line.composited(over: texturedImage())
        let mask = CIImage(color: .white).cropped(to: image.extent)
        let before = render(image, ctx)
        let out = render(PortraitRetouch.smooth(image, mask: mask, faceWidth: 400, level: 10), ctx)
        // 沿 y 平均：斑駁在 y 方向剛好 10 個週期，平均後只剩亮邊造成的變化。
        func columnChange(_ x: Int) -> Double {
            (0..<400).map { Double(out[($0 * 400 + x) * 4] - before[($0 * 400 + x) * 4]) }.reduce(0, +) / 400
        }
        for x in [95, 97, 98, 104, 105, 107] {
            XCTAssertEqual(columnChange(x), 0, accuracy: 0.004, "x = \(x) 出現亮邊")
        }
        XCTAssertEqual(columnChange(101), 0, accuracy: 0.004, "線本身被抹淡")
    }

    func testSmoothingStrengthFollowsLevel() {
        let ctx = context()
        let image = texturedImage()
        let mask = CIImage(color: .white).cropped(to: image.extent)
        let low = measure(render(PortraitRetouch.smooth(image, mask: mask, faceWidth: 400, level: 2), ctx), x0: 0, x1: 400)
        let high = measure(render(PortraitRetouch.smooth(image, mask: mask, faceWidth: 400, level: 9), ctx), x0: 0, x1: 400)
        XCTAssertGreaterThan(low.blotch, high.blotch * 1.5)
    }
}
