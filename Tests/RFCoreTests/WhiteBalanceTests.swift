import XCTest
@testable import RFCore

final class WhiteBalanceTests: XCTestCase {
    func testPresetValuesAreCentralizedAndComplete() {
        XCTAssertEqual(WhiteBalancePreset.daylight.defaultValues, WhiteBalanceValues(temperature: 5500, tint: 0))
        XCTAssertEqual(WhiteBalancePreset.cloudy.defaultValues, WhiteBalanceValues(temperature: 6500, tint: 0.01))
        XCTAssertEqual(WhiteBalancePreset.shade.defaultValues, WhiteBalanceValues(temperature: 7500, tint: 0.02))
        XCTAssertEqual(WhiteBalancePreset.tungsten.defaultValues, WhiteBalanceValues(temperature: 3200, tint: 0))
        XCTAssertEqual(WhiteBalancePreset.fluorescent.defaultValues, WhiteBalanceValues(temperature: 4000, tint: 0))
        XCTAssertEqual(WhiteBalancePreset.flash.defaultValues, WhiteBalanceValues(temperature: 5500, tint: 0))
        XCTAssertNil(WhiteBalancePreset.asShot.defaultValues)
        XCTAssertNil(WhiteBalancePreset.auto.defaultValues)
        XCTAssertNil(WhiteBalancePreset.custom.defaultValues)
    }

    func testManualChangeClampsAndMarksCustom() {
        var wb = WhiteBalanceParameters()
        wb.select(.daylight)
        XCTAssertEqual(wb.preset, .daylight)

        wb.temperature = 12_500
        XCTAssertEqual(wb.temperature, 12_000)
        XCTAssertEqual(wb.preset, .custom)

        wb.tint = -1
        XCTAssertEqual(wb.tint, -0.1)
        XCTAssertEqual(wb.preset, .custom)
    }

    func testAsShotUsesRawMetadataInBothControls() {
        var metadata = RawMetadata()
        metadata.neutralTemperature = 5708.52
        metadata.neutralTint = 10.4973

        let reading = metadata.asShotWhiteBalance
        XCTAssertEqual(reading.temperature, 5708.52)
        XCTAssertEqual(try XCTUnwrap(reading.tint),
                       -10.4973 / SceneNormalization.filterTintPerChromaticityUnit,
                       accuracy: 1e-12)

        var parameters = EditParameters()
        parameters.layerA.whiteBalance.select(.asShot)
        let transform = RenderPipeline.sceneTransform(for: parameters, metadata: metadata)
        XCTAssertEqual(transform.whiteBalanceGains.x, 1, accuracy: 1e-9)
        XCTAssertEqual(transform.whiteBalanceGains.y, 1, accuracy: 1e-9)
        XCTAssertEqual(transform.whiteBalanceGains.z, 1, accuracy: 1e-9)
    }

    func testMissingAsShotDoesNotUseFixedFallback() {
        var parameters = EditParameters()
        parameters.layerA.whiteBalance.select(.daylight)
        let transform = RenderPipeline.sceneTransform(for: parameters, metadata: RawMetadata())

        XCTAssertEqual(transform.whiteBalanceGains, SIMD3(repeating: 1),
                       "缺少 camera WB 時不可用固定 5500 K / tint 0 假冒 As Shot")
    }

    func testExistingCustomSidecarWithoutCameraWhiteBalanceMetadataKeepsIdentity() throws {
        let data = Data(#"{"whiteBalance":{"preset":"custom","temperature":5500,"tint":0}}"#.utf8)
        let layer = try JSONDecoder().decode(LayerATechnical.self, from: data)
        var parameters = EditParameters()
        parameters.layerA = layer

        let transform = RenderPipeline.sceneTransform(for: parameters, metadata: RawMetadata())

        XCTAssertEqual(transform.whiteBalanceGains, SIMD3(repeating: 1),
                       "既有 Custom sidecar 在缺少 camera WB 時不可改按 D65 重新解讀")
    }

    func testDaylightValuesSubmittedUnchangedAsCustomKeepIdentityWithoutMetadata() {
        var whiteBalance = WhiteBalanceParameters()
        whiteBalance.select(.daylight)
        whiteBalance.setTemperature(5500)
        XCTAssertEqual(whiteBalance.preset, .custom)
        XCTAssertEqual(whiteBalance.temperature, 5500)
        XCTAssertEqual(whiteBalance.tint, 0)

        var parameters = EditParameters()
        parameters.layerA.whiteBalance = whiteBalance
        let transform = RenderPipeline.sceneTransform(for: parameters, metadata: RawMetadata())

        XCTAssertEqual(transform.whiteBalanceGains, SIMD3(repeating: 1),
                       "將相同的 5500 K / tint 0 提交成 Custom 不應改變既有算圖")
    }

    func testLUTCacheSeparatesCameraTint() {
        var first = RawMetadata()
        first.cameraModel = "same-camera"
        first.neutralTemperature = 5600
        first.neutralTint = 0
        var second = first
        second.neutralTint = 24

        let firstKey = LUTCache.Key(parameters: EditParameters(), target: RenderingTarget(), metadata: first)
        let secondKey = LUTCache.Key(parameters: EditParameters(), target: RenderingTarget(), metadata: second)

        XCTAssertEqual(firstKey.neutralTint, 0)
        XCTAssertEqual(secondKey.neutralTint, 24)
        XCTAssertNotEqual(firstKey.neutralTint, secondKey.neutralTint,
                          "As Shot camera Tint 不同時不可共用同一顆 LUT")
    }

    func testLegacyLayerATemperatureAndTintDecodeIntoCustomWB() throws {
        let data = Data(#"{"temperature":4800,"tint":0.02,"exposureEV":-0.5}"#.utf8)
        let layer = try JSONDecoder().decode(LayerATechnical.self, from: data)

        XCTAssertEqual(layer.whiteBalance.preset, .custom)
        XCTAssertEqual(layer.temperature, 4800)
        XCTAssertEqual(layer.tint, 0.02)
        XCTAssertEqual(layer.exposureEV, -0.5)
    }

    func testAutoManualHandoffRoundTripsWithExistingSidecarKeys() throws {
        var state = WhiteBalanceParameters(preset: .auto)
        state.prepareForManualAdjustment(current: WhiteBalanceReading(temperature: 5200, tint: 0.018))
        state.setTint(-0.025)

        let data = try JSONEncoder().encode(state)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["preset", "temperature", "tint"]))
        XCTAssertEqual(try JSONDecoder().decode(WhiteBalanceParameters.self, from: data), state)
    }

    func testTintDisplayUsesIntegerScaleWithoutChangingRenderValue() {
        XCTAssertEqual(WhiteBalanceParameters.tintDisplayRange, -100...100)
        XCTAssertEqual(WhiteBalanceParameters.tintDisplayValue(0.012), 12, accuracy: 1e-9)
        XCTAssertEqual(WhiteBalanceParameters.tintFromDisplay(12), 0.012, accuracy: 1e-12)
        XCTAssertEqual(WhiteBalanceParameters.tintFromDisplay(150), 0.1,
                       "輸入超出範圍時限制在算圖可用的 Tint 上限")
    }
}
