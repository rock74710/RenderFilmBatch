import XCTest
import CoreImage
@testable import RFCore

/// 遮色片的基本／色彩／效果：只在遮色片內改變，舊設定不受影響。
final class LocalMaskAdjustmentTests: XCTestCase {
    /// 上半部遮色片強度 1，下半部 0。
    private func topMask() -> LocalMask {
        var m = LocalMask(kind: .gradient)
        m.start = .init(x: 0.5, y: 0.45)
        m.end = .init(x: 0.5, y: 0.55)
        return m
    }

    /// 有紋理、帶顏色的場景線性棋盤：亮格約 +3 EV、暗格約 −4 EV，白色／黑色才有作用範圍。
    private func source(_ gpu: GPUContext) -> CIImage {
        let space = gpu.workingColorSpace
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputCenter": CIVector(x: 0, y: 0),
            "inputColor0": CIColor(red: 2.0, green: 1.4, blue: 0.8, colorSpace: space)!,
            "inputColor1": CIColor(red: 0.016, green: 0.01, blue: 0.006, colorSpace: space)!,
            "inputWidth": 3.0, "inputSharpness": 1.0,
        ])!.outputImage!
        return checker.cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    private func pixels(_ image: CIImage, _ gpu: GPUContext, y: CGFloat) -> [Float] {
        var p = [Float](repeating: 0, count: 100 * 10 * 4)
        gpu.ciContext.render(image, toBitmap: &p, rowBytes: 100 * 16,
                             bounds: CGRect(x: 0, y: y, width: 100, height: 10),
                             format: .RGBAf, colorSpace: gpu.workingColorSpace)
        return p
    }

    /// 相對差異，暗格的變化才不會被亮格蓋過。
    private func maxDiff(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).map { abs($0 - $1) / (abs($1) + 0.001) }.max() ?? 0
    }

    private var cases: [(String, (inout LocalMask) -> Void)] {
        [
            ("contrast", { $0.toneAdjustment = .init(contrast: 0.5) }),
            ("highlights", { $0.toneAdjustment = .init(highlights: 0.5) }),
            ("shadows", { $0.toneAdjustment = .init(shadows: 0.5) }),
            ("whites", { $0.toneAdjustment = .init(whites: 0.5) }),
            ("blacks", { $0.toneAdjustment = .init(blacks: 0.5) }),
            ("hueShift", { $0.colorAdjustment = .init(hueShift: 90) }),
            ("texture", { $0.effectAdjustment = .init(texture: 0.5) }),
            ("clarity", { $0.effectAdjustment = .init(clarity: 0.5) }),
            ("dehaze", { $0.effectAdjustment = .init(dehaze: -0.5) }),
        ]
    }

    func testEachNewAdjustmentChangesOnlyInsideMask() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let renderer = try MaskRenderer()
        let src = source(gpu)
        for (name, set) in cases {
            var mask = topMask()
            set(&mask)
            XCTAssertTrue(mask.hasActiveAdjustment, name)
            let out = try renderer.apply([mask], to: src)
            XCTAssertGreaterThan(maxDiff(pixels(out, gpu, y: 85), pixels(src, gpu, y: 85)), 0.05, "\(name) 遮色片內應改變")
            XCTAssertLessThan(maxDiff(pixels(out, gpu, y: 5), pixels(src, gpu, y: 5)), 0.001, "\(name) 遮色片外不應改變")
        }
    }

    func testZeroNewAdjustmentsMatchLegacyOutput() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let renderer = try MaskRenderer()
        let src = source(gpu)
        var legacy = topMask()
        legacy.exposureEV = 0.7
        legacy.colorAdjustment = .init(temperature: 800, tint: 10, chroma: 1.3)
        var zeroed = legacy
        zeroed.toneAdjustment = .init()
        zeroed.effectAdjustment = .init()
        let a = try renderer.apply([legacy], to: src)
        let b = try renderer.apply([zeroed], to: src)
        XCTAssertEqual(maxDiff(pixels(a, gpu, y: 85), pixels(b, gpu, y: 85)), 0)
        var neutral = topMask()
        neutral.toneAdjustment = .init()
        neutral.effectAdjustment = .init()
        neutral.colorAdjustment = .init()
        XCTAssertFalse(neutral.hasActiveAdjustment)
    }

    func testLegacyJSONDecodesAndNewFieldsRoundTrip() throws {
        var mask = topMask()
        mask.colorAdjustment = .init(temperature: 100, tint: 5, chroma: 1.2)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(mask)) as? [String: Any])
        var color = try XCTUnwrap(legacy["colorAdjustment"] as? [String: Any])
        color.removeValue(forKey: "hueShift")
        legacy["colorAdjustment"] = color
        let decoded = try JSONDecoder().decode(LocalMask.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.colorAdjustment?.hueShift, 0)
        XCTAssertEqual(decoded.colorAdjustment?.chroma, 1.2)
        XCTAssertNil(decoded.toneAdjustment)
        XCTAssertNil(decoded.effectAdjustment)

        mask.toneAdjustment = .init(contrast: 0.1, highlights: -0.2, shadows: 0.3, whites: -0.4, blacks: 0.5)
        mask.effectAdjustment = .init(texture: 0.6, clarity: -0.7, dehaze: 0.8)
        mask.colorAdjustment?.hueShift = -45
        XCTAssertEqual(try JSONDecoder().decode(LocalMask.self, from: JSONEncoder().encode(mask)), mask)
    }
}
