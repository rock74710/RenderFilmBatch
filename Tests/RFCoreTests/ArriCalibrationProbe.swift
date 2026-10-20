import XCTest
import simd
@testable import RFCore

/// 校正探測：把 FilmRe/tools 產生的 scene XYZ 取樣送進實際的 SceneTransform + TargetTransform，
/// 輸出 SDR 顯示端 XYZ。只在設定 RF_PROBE_IN / RF_PROBE_OUT 時執行，平常測試會略過。
final class ArriCalibrationProbe: XCTestCase {
    private struct Variant: Decodable {
        let midtoneContrast: Double
        let shadowShaping: Double
        let highlightRollOff: Double
        let film: FilmParameters?
    }

    private struct Input: Decodable {
        let xyz: [[Double]]
        let variants: [Variant]
        let gamut: RenderingTarget.Gamut?
    }

    func testProbe() throws {
        let env = ProcessInfo.processInfo.environment
        guard let inPath = env["RF_PROBE_IN"], let outPath = env["RF_PROBE_OUT"] else {
            throw XCTSkip("RF_PROBE_IN / RF_PROBE_OUT not set")
        }
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: inPath)))
        var base = EditParameters()
        if let gamut = input.gamut { base.target.gamut = gamut }
        let working = RGBColorSpace.workingRec2020
        let display = base.target.gamut.colorSpace

        var outputs: [[[Double]]] = []
        for variant in input.variants {
            var tone = base.toneMapping
            tone.midtoneContrast = variant.midtoneContrast
            tone.shadowShaping = variant.shadowShaping
            tone.highlightRollOff = variant.highlightRollOff
            let film = variant.film ?? FilmParameters()
            let scene = SceneTransform(layerA: base.layerA, colorEngine: base.colorEngine, film: film)
            let target = TargetTransform(target: base.target, tone: tone, gamut: base.gamutMapping, film: film)
            outputs.append(input.xyz.map { xyz in
                let rgb = working.fromXYZ(SIMD3(xyz[0], xyz[1], xyz[2]))
                let lin = simd_clamp(target.targetLinear(scene.apply(rgb)), SIMD3(repeating: 0), SIMD3(repeating: 1))
                let out = display.toXYZ(lin)
                return [out.x, out.y, out.z]
            })
        }
        try JSONSerialization.data(withJSONObject: ["outputs": outputs])
            .write(to: URL(fileURLWithPath: outPath))
    }
}
