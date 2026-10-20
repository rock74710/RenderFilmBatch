import XCTest
import simd
@testable import RFCore

/// A-068：每個區塊都有啟用開關；關掉時渲染把該區塊當成初始值，參數本身保留。
final class SectionEnableTests: XCTestCase {
    private func edited() -> EditParameters {
        var p = EditParameters()
        p.layerA.exposureEV = 1.5
        p.layerA.chroma = 1.4
        p.colorMixer.bands[ColorMixerBand.orange.index].saturationShift = 0.4
        p.finishing.finalContrast = 0.35
        p.spatial.clarity = 0.4
        return p
    }

    func testDisabledSectionsRenderAsDefaultsButKeepValues() {
        var p = edited()
        p.layerA.enabled = false
        p.colorMixer.enabled = false
        p.finishing.enabled = false
        p.spatial.enabled = false

        let e = p.effective
        XCTAssertEqual(e.layerA.exposureEV, 0)
        XCTAssertEqual(e.layerA.chroma, 1)
        XCTAssertTrue(e.colorMixer.isNeutral)
        XCTAssertEqual(e.finishing.finalContrast, 0)
        XCTAssertTrue(e.spatial.isNeutral)
        // 使用者的數值仍在，重新打開就回來。
        XCTAssertEqual(p.layerA.exposureEV, 1.5)
        XCTAssertEqual(p.spatial.clarity, 0.4)
    }

    func testEnabledSectionsAreUntouched() {
        let p = edited()
        XCTAssertEqual(p.effective, p)
    }

    func testDisabledLayerAMatchesNeutralSceneTransform() {
        var p = edited()
        p.colorMixer = ColorMixerParameters()
        p.layerA.enabled = false
        let meta = RawMetadata()
        let off = RenderPipeline.sceneTransform(for: p, metadata: meta)
        let neutral = RenderPipeline.sceneTransform(for: EditParameters(), metadata: meta)
        let c = SIMD3<Double>(0.3, 0.2, 0.1)
        XCTAssertEqual(off.apply(c), neutral.apply(c))
    }

    func testEnabledFlagsRoundTripAndDefaultOnForOldSidecars() throws {
        var p = edited()
        p.layerA.enabled = false
        p.colorMixer.enabled = false
        p.finishing.enabled = false
        p.spatial.enabled = false
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(EditParameters.self, from: data), p)

        let old = try JSONEncoder().encode(EditParameters())
        var json = try JSONSerialization.jsonObject(with: old) as! [String: Any]
        for key in ["layerA", "colorMixer", "finishing", "spatial"] {
            var section = json[key] as! [String: Any]
            section.removeValue(forKey: "enabled")
            json[key] = section
        }
        let legacy = try JSONDecoder().decode(
            EditParameters.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(legacy.layerA.enabled && legacy.colorMixer.enabled
                      && legacy.finishing.enabled && legacy.spatial.enabled)
    }
}
