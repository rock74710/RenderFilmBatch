import XCTest
import simd
@testable import RFCore

final class ColorMathTests: XCTestCase {
    /// 驗收條件 3：OKLCH 往返誤差 < 1e-4。
    func testOKLabRoundTrip() {
        let samples: [SIMD3<Double>] = [
            SIMD3(0.18, 0.18, 0.18),
            SIMD3(1.0, 0.5, 0.2),
            SIMD3(0.02, 0.3, 0.7),
            SIMD3(4.0, 3.5, 3.0),      // 高光，超出 [0,1]
            SIMD3(0.001, 0.001, 0.001),
        ]
        let space = RGBColorSpace.workingRec2020
        for rgb in samples {
            let lab = OKLab.fromXYZ(space.toXYZ(rgb))
            let back = space.fromXYZ(OKLab.toXYZ(lab))
            XCTAssertEqual(back.x, rgb.x, accuracy: 1e-4)
            XCTAssertEqual(back.y, rgb.y, accuracy: 1e-4)
            XCTAssertEqual(back.z, rgb.z, accuracy: 1e-4)

            let lch = OKLab.toLCH(lab)
            let lab2 = OKLab.fromLCH(lch)
            XCTAssertEqual(lab2.y, lab.y, accuracy: 1e-9)
            XCTAssertEqual(lab2.z, lab.z, accuracy: 1e-9)
        }
    }

    /// 中性灰在 OKLab 下 chroma 必須為 0，否則整條色彩鏈都會帶色偏。
    func testNeutralGrayHasZeroChroma() {
        for v in [0.05, 0.18, 0.5, 1.0, 3.0] {
            let lch = OKLab.toLCH(OKLab.fromXYZ(
                RGBColorSpace.workingRec2020.toXYZ(SIMD3(repeating: v))
            ))
            // OKLab 的矩陣以 D65 定義，與由 xy 推導的 Rec.2020 白點有約 1e-4 的
            // 數值差；遠小於可見差異（約 2e-3），不需要為此調整矩陣。
            XCTAssertLessThan(lch.y, 5e-4, "灰階 \(v) 的 chroma 應為 0")
        }
    }

    /// 色域矩陣：白點 (1,1,1) 應對應到 D65。
    func testWhitePointMapsToD65() {
        for space in [RGBColorSpace.sRGB, .displayP3, .workingRec2020] {
            let xyz = space.toXYZ(SIMD3(1, 1, 1))
            let sum = xyz.x + xyz.y + xyz.z
            XCTAssertEqual(xyz.x / sum, 0.3127, accuracy: 1e-3, space.name)
            XCTAssertEqual(xyz.y / sum, 0.3290, accuracy: 1e-3, space.name)
        }
    }

    func testCrossSpaceMatrixIsInvertible() {
        let m = RGBColorSpace.workingRec2020.matrix(to: .displayP3)
        let back = m.inverse
        let v = SIMD3<Double>(0.3, 0.6, 0.2)
        let r = back(m(v))
        XCTAssertEqual(r.x, v.x, accuracy: 1e-9)
        XCTAssertEqual(r.y, v.y, accuracy: 1e-9)
        XCTAssertEqual(r.z, v.z, accuracy: 1e-9)
    }

    func testHueDelta() {
        XCTAssertEqual(hueDelta(10, 350), 20, accuracy: 1e-9)
        XCTAssertEqual(hueDelta(350, 10), -20, accuracy: 1e-9)
        XCTAssertEqual(hueDelta(90, 90), 0, accuracy: 1e-9)
    }

    /// 6504K 必須準確落在 D65，否則整條 pipeline 的中性點就偏了。
    func testD65Chromaticity() {
        let xy = SceneNormalization.chromaticity(temperature: 6504)
        XCTAssertEqual(xy.x, 0.3127, accuracy: 5e-4)
        XCTAssertEqual(xy.y, 0.3290, accuracy: 5e-4)
    }

    /// D65 的白平衡增益應為 1：中性色不能被整體偏移。
    func testDaylightGainsAreNearUnity() {
        let g = SceneNormalization.whiteBalanceGains(temperature: 6504, tint: 0)
        XCTAssertEqual(g.x, 1.0, accuracy: 0.005)
        XCTAssertEqual(g.y, 1.0, accuracy: 1e-9)
        XCTAssertEqual(g.z, 1.0, accuracy: 0.005)
    }

    /// 色溫越低，白平衡增益必須讓紅通道相對變小（抵銷偏黃的光源）。
    func testWhiteBalanceGainDirection() {
        let tungsten = SceneNormalization.whiteBalanceGains(temperature: 2850, tint: 0)
        let daylight = SceneNormalization.whiteBalanceGains(temperature: 5500, tint: 0)
        XCTAssertLessThan(tungsten.x / tungsten.z, daylight.x / daylight.z)
    }
}
