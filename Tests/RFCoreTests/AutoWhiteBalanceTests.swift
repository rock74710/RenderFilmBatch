import XCTest
@testable import RFCore

final class AutoWhiteBalanceTests: XCTestCase {
    func testNeutralPixelsKeepCameraWhiteBalance() {
        let pixels: [Float] = Array(repeating: [0.3, 0.3, 0.3, 1], count: 100).flatMap { $0 }
        let result = AutoWhiteBalance.analyzeRGBA(pixels)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.gains.x, 1, accuracy: 0.0001)
        XCTAssertEqual(result.gains.z, 1, accuracy: 0.0001)
    }

    func testWarmCastGetsRestrainedCorrection() {
        let pixels: [Float] = Array(repeating: [0.36, 0.3, 0.27, 1], count: 100).flatMap { $0 }
        let result = AutoWhiteBalance.analyzeRGBA(pixels)
        XCTAssertFalse(result.usedFallback)
        XCTAssertLessThan(result.gains.x, 1)
        XCTAssertGreaterThan(result.gains.z, 1)
    }

    func testSaturatedSceneFallsBackToCameraWhiteBalance() {
        let pixels: [Float] = Array(repeating: [0.8, 0.05, 0.05, 1], count: 100).flatMap { $0 }
        let result = AutoWhiteBalance.analyzeRGBA(pixels)
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.gains, SIMD3(repeating: 1))
    }

    func testAutoGainsAreAppliedOnlyWhenProvided() {
        let base = RenderPipeline.sceneTransform(for: EditParameters(), metadata: RawMetadata())
        let automatic = RenderPipeline.sceneTransform(for: EditParameters(), metadata: RawMetadata(),
                                                      autoWhiteBalanceGains: SIMD3(0.9, 1, 1.1))
        XCTAssertEqual(base.whiteBalanceGains, SIMD3(repeating: 1))
        XCTAssertEqual(automatic.whiteBalanceGains, SIMD3(0.9, 1, 1.1))
    }

    func testAutoPresetAnalyzesTheSceneMasterImage() throws {
        guard let gpu = GPUContext.shared else { throw XCTSkip("此測試需要 Metal 裝置") }
        let pipeline = try RenderPipeline(gpu: gpu)
        let pixels: [Float] = Array(repeating: [0.36, 0.3, 0.27, 1], count: 100).flatMap { $0 }
        let data = pixels.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: data, bytesPerRow: 4 * 4 * 10,
                            size: CGSize(width: 10, height: 10), format: .RGBAf,
                            colorSpace: gpu.workingColorSpace)
        let metadata = RawMetadata()
        let resolution = pipeline.profileManager.resolve(
            metadata: metadata, preference: .force(.off), manual: nil,
            appleCorrectionSupported: false
        )
        let scene = SceneLinearImage(image: image, metadata: metadata,
                                     versions: PipelineVersions(), lensResolution: resolution)
        var parameters = EditParameters()
        parameters.layerA.whiteBalance.select(.auto)

        let result = AutoWhiteBalance.analyze(image, context: gpu.ciContext)
        let master = pipeline.makeSceneMaster(sceneLinear: scene, parameters: parameters)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(master.sceneTransform.whiteBalanceGains, result.gains,
                       "Auto 必須在共用 Scene Master 入口分析中性色並套用修正")

        let asShotMaster = pipeline.makeSceneMaster(sceneLinear: scene, parameters: EditParameters())
        XCTAssertEqual(asShotMaster.sceneTransform.whiteBalanceGains, SIMD3(repeating: 1),
                       "As Shot 不應啟動 Auto 分析")

        let explicitGains = SIMD3(0.9, 1, 1.1)
        let explicitMaster = pipeline.makeSceneMaster(
            sceneLinear: scene, parameters: parameters, autoWhiteBalanceGains: explicitGains
        )
        XCTAssertEqual(explicitMaster.sceneTransform.whiteBalanceGains, explicitGains,
                       "外部提供的 gains 優先使用，避免批次匯出重複套用")

        let saturatedPixels: [Float] = Array(repeating: [0.8, 0.05, 0.05, 1], count: 100).flatMap { $0 }
        let saturatedData = saturatedPixels.withUnsafeBytes { Data($0) }
        let saturatedImage = CIImage(bitmapData: saturatedData, bytesPerRow: 4 * 4 * 10,
                                     size: CGSize(width: 10, height: 10), format: .RGBAf,
                                     colorSpace: gpu.workingColorSpace)
        let saturatedScene = SceneLinearImage(image: saturatedImage, metadata: metadata,
                                              versions: PipelineVersions(), lensResolution: resolution)
        let fallback = pipeline.makeSceneMaster(sceneLinear: saturatedScene, parameters: parameters)
        XCTAssertEqual(fallback.sceneTransform.whiteBalanceGains, SIMD3(repeating: 1),
                       "沒有可靠中性色時保留拍攝設定")
    }

    func testAutoCorrectionCanTransferToManualTemperatureAndTint() throws {
        let gains = SIMD3(0.9, 1, 1.1)
        let asShot = WhiteBalanceValues(temperature: 5600, tint: 0.01)
        let values = AutoWhiteBalance.whiteBalanceValues(matching: gains, asShot: asShot)
        let matched = SceneNormalization.whiteBalanceGains(
            temperature: values.temperature, tint: values.tint,
            asShotTemperature: 5600, asShotTint: 0.01
        )
        XCTAssertEqual(matched.x, gains.x, accuracy: 0.005)
        XCTAssertEqual(matched.z, gains.z, accuracy: 0.005)

        var state = WhiteBalanceParameters(preset: .auto)
        state.prepareForManualAdjustment(current: WhiteBalanceReading(
            temperature: values.temperature, tint: values.tint
        ))
        state.setTemperature(values.temperature + 50)
        XCTAssertEqual(state.preset, .custom)
        XCTAssertEqual(state.temperature, values.temperature + 50)
        XCTAssertEqual(try XCTUnwrap(state.tint), values.tint, accuracy: 1e-12,
                       "調整色溫時保留 Auto 對應的 Tint")
    }

    func testDifferentAutoGainsCannotReuseSameLUT() {
        let parameters = EditParameters()
        let target = parameters.target
        let metadata = RawMetadata()
        let first = LUTCache.Key(parameters: parameters, target: target, metadata: metadata,
                                 sceneWhiteBalanceGains: SIMD3(0.9, 1, 1.1))
        let second = LUTCache.Key(parameters: parameters, target: target, metadata: metadata,
                                  sceneWhiteBalanceGains: SIMD3(1.1, 1, 0.9))
        XCTAssertNotEqual(first, second)
    }
}
