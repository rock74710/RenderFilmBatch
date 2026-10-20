import XCTest
import CoreImage
import simd
@testable import RFCore

/// §11 Layer C Finishing 的空間性效果（A-033 M2）。
///
/// 這些效果要看鄰近像素或像素座標，進不了 3D LUT，所以在 LUT 之後單獨跑一段。
final class SpatialFinishingTests: XCTestCase {

    // MARK: - 參數與 sidecar

    func testDefaultIsNeutral() {
        XCTAssertTrue(SpatialFinishingParameters().isNeutral)
        XCTAssertTrue(EditParameters().isDefault(.spatial))
    }

    func testLegacySidecarWithoutSpatialIsNeutral() throws {
        let json = """
        {"layerA":{"exposureEV":0,"highlightRecovery":0,"shadowRecovery":0,\
        "linearContrast":0,"chroma":1},"colorEngine":{},\
        "toneMapping":{"shoulderStart":0.6,"highlightRollOff":0.7,"shadowShaping":0,\
        "midtoneContrast":1,"diffuseWhite":1},\
        "gamutMapping":{"knee":0.85,"lightnessAdapt":0.15,"enabled":true},\
        "optical":{"enabled":true},"target":{}}
        """
        let p = try JSONDecoder().decode(EditParameters.self, from: Data(json.utf8))
        XCTAssertTrue(p.spatial.isNeutral)
        XCTAssertNil(p.spatial.clarityOffsets, "a sidecar without the spatial object stays on the legacy clarity path")
        XCTAssertTrue(p.isDefault(.spatial))
        XCTAssertTrue(p.isDefaultAll, "a legacy neutral sidecar is still an all-default edit")
    }

    func testRoundTripKeepsSpatial() throws {
        var p = EditParameters()
        p.spatial.grain.amount = 0.4
        p.spatial.grain.size = 0.8
        p.spatial.vignette.amount = -0.3
        p.spatial.sharpening.amount = 0.6
        p.spatial.texture = 0.25
        p.spatial.clarity = -0.5
        p.spatial.glow.amount = 0.35
        p.spatial.dehaze = 0.7
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(EditParameters.self, from: data)
        XCTAssertEqual(back.spatial, p.spatial)
        XCTAssertFalse(back.spatial.isNeutral)
    }

    func testResetSectionRestoresDefaults() {
        var p = EditParameters()
        p.spatial.dehaze = 0.5
        p.spatial.grain.amount = 0.2
        p.layerA.exposureEV = 1.5
        XCTAssertFalse(p.isDefault(.spatial))
        p.reset(.spatial)
        XCTAssertTrue(p.isDefault(.spatial))
        XCTAssertEqual(p.layerA.exposureEV, 1.5, "重置一個區塊不應動到其他區塊")
    }

    /// 每一項單獨開啟都必須讓 `isNeutral` 變成 false，否則會被誤判成可略過。
    func testEachEffectBreaksNeutrality() {
        var cases: [SpatialFinishingParameters] = []
        var p = SpatialFinishingParameters(); p.grain.amount = 0.1; cases.append(p)
        p = SpatialFinishingParameters(); p.vignette.amount = 0.1; cases.append(p)
        p = SpatialFinishingParameters(); p.sharpening.amount = 0.1; cases.append(p)
        p = SpatialFinishingParameters(); p.texture = 0.1; cases.append(p)
        p = SpatialFinishingParameters(); p.clarity = 0.1; cases.append(p)
        p = SpatialFinishingParameters(); p.glow.amount = 0.1; cases.append(p)
        p = SpatialFinishingParameters(); p.dehaze = 0.1; cases.append(p)
        for c in cases { XCTAssertFalse(c.isNeutral) }
        XCTAssertEqual(cases.count, 7)
    }

    // MARK: - 像素行為

    private var gpu: GPUContext!
    private var renderer: SpatialRenderer!

    override func setUpWithError() throws {
        gpu = try XCTUnwrap(GPUContext.shared, "此測試需要 Metal 裝置")
        renderer = try SpatialRenderer()
    }

    /// 生成測試影像。`value(x, y)` 回傳 0…1 的灰階值（三通道相同）。
    private func image(size: Int = 128, _ value: (Int, Int) -> Double) -> CIImage {
        var pixels = [Float](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let v = Float(value(x, y))
                pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v; pixels[i + 3] = 1
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: size * 4 * MemoryLayout<Float>.size,
                       size: CGSize(width: size, height: size), format: .RGBAf,
                       colorSpace: gpu.workingColorSpace)
    }

    private func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> Double {
        var out = [Float](repeating: 0, count: 4)
        gpu.ciContext.render(image, toBitmap: &out, rowBytes: 4 * MemoryLayout<Float>.size,
                             bounds: CGRect(x: x, y: y, width: 1, height: 1),
                             format: .RGBAf, colorSpace: gpu.workingColorSpace)
        return Double(out[0])
    }

    func testNeutralReturnsSameImage() throws {
        let source = image { _, _ in 0.5 }
        let out = try renderer.apply(SpatialFinishingParameters(), to: source)
        XCTAssertTrue(out === source, "中性參數不應掛上任何 filter")
    }

    func testPositiveVignetteDarkensCornersOnly() throws {
        let source = image { _, _ in 0.5 }
        var p = SpatialFinishingParameters()
        p.vignette.amount = 0.8
        let out = try renderer.apply(p, to: source)
        XCTAssertEqual(pixel(out, 64, 64), 0.5, accuracy: 1e-4, "中心不該被動到")
        XCTAssertLessThan(pixel(out, 1, 1), 0.45, "四角應變暗")
    }

    func testNegativeVignetteBrightensCorners() throws {
        let source = image { _, _ in 0.5 }
        var p = SpatialFinishingParameters()
        p.vignette.amount = -0.8
        let out = try renderer.apply(p, to: source)
        XCTAssertGreaterThan(pixel(out, 1, 1), 0.55)
    }

    func testGrainPerturbsFlatField() throws {
        let source = image { _, _ in 0.5 }
        var p = SpatialFinishingParameters()
        p.grain.amount = 1.0
        p.grain.size = 0.0
        let out = try renderer.apply(p, to: source)
        let samples = (0..<16).map { pixel(out, 20 + $0 * 4, 64) }
        XCTAssertTrue(samples.contains { abs($0 - 0.5) > 0.002 }, "顆粒應造成逐像素差異")
        let mean = samples.reduce(0, +) / Double(samples.count)
        XCTAssertEqual(mean, 0.5, accuracy: 0.05, "顆粒不該整體改變亮度")
    }

    func testGrainStrengthPresetsAndLegacyDecoding() throws {
        let old = try JSONDecoder().decode(GrainParameters.self,
            from: Data(#"{"amount":0.4,"size":0.8,"roughness":0.3}"#.utf8))
        XCTAssertFalse(old.randomized)
        XCTAssertEqual(old.amount, 0.4)
        XCTAssertTrue(GrainParameters().randomized)
        var p = GrainParameters()
        for strength in GrainStrength.allCases {
            p.apply(strength)
            XCTAssertEqual(p.strength, strength)
            XCTAssertTrue(p.randomized)
            XCTAssertFalse(p.isNeutral)
            XCTAssertEqual(try JSONDecoder().decode(GrainParameters.self,
                from: JSONEncoder().encode(p)), p)
        }
    }

    private func grainPixels(_ image: CIImage, size: Int) -> [Float] {
        var out = [Float](repeating: 0, count: size * size * 4)
        gpu.ciContext.render(image, toBitmap: &out,
            rowBytes: size * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: size, height: size),
            format: .RGBAf, colorSpace: gpu.workingColorSpace)
        return stride(from: 0, to: out.count, by: 4).map { out[$0] }
    }

    func testGrainStrengthIncreasesVarianceAndIsRepeatable() throws {
        let source = image(size: 512) { _, _ in 0.5 }
        var previous = 0.0
        for strength in GrainStrength.allCases {
            var p = SpatialFinishingParameters()
            p.grain.apply(strength)
            let output = try renderer.apply(p, to: source)
            let a = grainPixels(output, size: 512)
            let b = grainPixels(try renderer.apply(p, to: source), size: 512)
            XCTAssertEqual(a, b, "重算同一設定不應改變花紋")
            let mean = a.reduce(0.0) { $0 + Double($1) } / Double(a.count)
            let variance = a.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(a.count)
            XCTAssertGreaterThan(variance, previous)
            XCTAssertEqual(mean, 0.5, accuracy: 0.002)
            previous = variance
        }
    }

    func testRandomGrainHasVaryingSizesAndIrregularGaps() throws {
        let source = image(size: 1024) { _, _ in 0.5 }
        var p = SpatialFinishingParameters()
        p.grain.apply(.strong)
        p.grain.size = 1
        let values = grainPixels(try renderer.apply(p, to: source), size: 1024)
        var widths = Set<Int>()
        var gaps = Set<Int>()
        for y in stride(from: 32, to: 992, by: 32) {
            var run = 0
            var gap = 0
            for x in 0..<1024 {
                if abs(values[y * 1024 + x] - 0.5) > 0.004 {
                    if gap > 0 { gaps.insert(gap); gap = 0 }
                    run += 1
                } else {
                    if run > 0 { widths.insert(run); run = 0 }
                    gap += 1
                }
            }
        }
        XCTAssertGreaterThan(widths.count, 3, "顆粒截面應有不同大小")
        XCTAssertGreaterThan(gaps.count, 3, "分佈應有不規則間距")
    }

    /// 清晰度是局部對比：邊界亮側更亮、暗側更暗。
    func testPositiveClarityIncreasesEdgeContrast() throws {
        let source = image { x, _ in x < 64 ? 0.3 : 0.7 }
        var p = SpatialFinishingParameters()
        p.clarity = 1.0
        let out = try renderer.apply(p, to: source)
        XCTAssertLessThan(pixel(out, 62, 64), 0.3 - 1e-3, "暗側應更暗")
        XCTAssertGreaterThan(pixel(out, 66, 64), 0.7 + 1e-3, "亮側應更亮")
    }

    func testNegativeClarityReducesEdgeContrast() throws {
        let source = image { x, _ in x < 64 ? 0.3 : 0.7 }
        var p = SpatialFinishingParameters()
        p.clarity = -1.0
        let out = try renderer.apply(p, to: source)
        XCTAssertGreaterThan(pixel(out, 62, 64), 0.3 + 1e-3)
        XCTAssertLessThan(pixel(out, 66, 64), 0.7 - 1e-3)
    }

    /// 清晰度可分暗部、中間調、亮部調整；暗部權重歸零後，暗區邊界幾乎不變，亮區邊界照常。
    func testClarityTonalWeightsLimitEffectToSelectedRange() throws {
        let darkEdge = image { x, _ in x < 64 ? 0.05 : 0.15 }
        let brightEdge = image { x, _ in x < 64 ? 0.85 : 0.95 }
        var full = SpatialFinishingParameters(); full.clarity = 1.0
        var noShadows = full; noShadows.clarityTones.shadows = 0
        func change(_ p: SpatialFinishingParameters, _ src: CIImage, base: Double) throws -> Double {
            abs(pixel(try renderer.apply(p, to: src), 66, 64) - base)
        }
        XCTAssertLessThan(try change(noShadows, darkEdge, base: 0.15),
                          try change(full, darkEdge, base: 0.15) * 0.3, "暗區效果應大幅減少")
        XCTAssertGreaterThan(try change(noShadows, brightEdge, base: 0.95),
                             try change(full, brightEdge, base: 0.95) * 0.9, "亮區效果應大致保留")
    }

    func testClarityTonesKeepSignedValuesWhenEncoded() throws {
        var tones = ClarityTonalRange()
        tones.shadows = -1
        tones.midtones = 0
        tones.highlights = 1
        let decoded = try JSONDecoder().decode(ClarityTonalRange.self, from: JSONEncoder().encode(tones))
        XCTAssertEqual(decoded.shadows, -1)
        XCTAssertEqual(decoded.midtones, 0)
        XCTAssertEqual(decoded.highlights, 1)
    }

    func testSignedClarityToneWeightsReverseOrDisableTheirRegionEffect() throws {
        let cases: [(String, CIImage, Double, (inout ClarityTonalRange, Double) -> Void)] = [
            ("shadows", image { x, _ in x < 64 ? 0.05 : 0.15 }, 0.15, { $0.shadows = $1 }),
            ("midtones", image { x, _ in x < 64 ? 0.45 : 0.55 }, 0.55, { $0.midtones = $1 }),
            ("highlights", image { x, _ in x < 64 ? 0.85 : 0.95 }, 0.95, { $0.highlights = $1 }),
        ]

        for (name, source, base, setWeight) in cases {
            func delta(_ weight: Double) throws -> Double {
                var p = SpatialFinishingParameters()
                p.clarity = 1
                var tones = ClarityTonalRange()
                tones.shadows = 0
                tones.midtones = 0
                tones.highlights = 0
                p.clarityTones = tones
                setWeight(&p.clarityTones, weight)
                return pixel(try renderer.apply(p, to: source), 66, 64) - base
            }

            let positive = try delta(1)
            let neutral = try delta(0)
            let negative = try delta(-1)
            XCTAssertGreaterThan(positive, 1e-3, "positive \(name) weight should increase edge contrast")
            XCTAssertEqual(neutral, 0, accuracy: 1e-5, "zero \(name) weight should disable that region")
            XCTAssertLessThan(negative, -1e-3, "negative \(name) weight should reverse edge contrast")
            XCTAssertEqual(positive, -negative, accuracy: 2e-3, "signed \(name) effects should reverse evenly")
        }
    }

    func testClarityTonesDecodeDefaultsWhenMissing() throws {
        let v = try JSONDecoder().decode(SpatialFinishingParameters.self, from: Data(#"{"clarity":0.5}"#.utf8))
        XCTAssertEqual(v.clarityTones, ClarityTonalRange())
        XCTAssertNil(v.clarityOffsets, "missing offsets identify the legacy multiplier mode")
    }

    func testClarityOffsetsDecodeDefaultsAndRoundTripBothModes() throws {
        let defaults = SpatialFinishingParameters()
        XCTAssertNil(defaults.clarityOffsets, "new parameters start on the legacy path until a zone offset is set")

        let legacy = try JSONDecoder().decode(SpatialFinishingParameters.self,
            from: Data(#"{"clarity":-0.4,"clarityTones":{"shadows":0.7}}"#.utf8))
        XCTAssertNil(legacy.clarityOffsets)
        let legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertNil(legacyJSON["clarityOffsets"], "legacy mode should remain omitted when encoded")

        let explicitNull = try JSONDecoder().decode(SpatialFinishingParameters.self,
            from: Data(#"{"clarityOffsets":null}"#.utf8))
        XCTAssertNil(explicitNull.clarityOffsets)

        var withoutSpatial = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(EditParameters.defaults)) as? [String: Any])
        withoutSpatial["spatial"] = NSNull()
        let absentSpatial = try JSONDecoder().decode(EditParameters.self,
            from: JSONSerialization.data(withJSONObject: withoutSpatial))
        XCTAssertNil(absentSpatial.spatial.clarityOffsets, "a null spatial block remains legacy")

        let partial = try JSONDecoder().decode(SpatialFinishingParameters.self,
            from: Data(#"{"clarityOffsets":{"highlights":-0.5}}"#.utf8))
        XCTAssertEqual(partial.clarityOffsets, ClarityOffsets(shadows: 0, midtones: 0, highlights: -0.5))
        XCTAssertEqual(try JSONDecoder().decode(SpatialFinishingParameters.self, from: JSONEncoder().encode(partial)), partial)
    }

    func testClarityOffsetsApplyAtZeroTotalAcrossTonalRegions() throws {
        let cases: [(String, CIImage, Double, (inout ClarityOffsets, Double) -> Void, Bool)] = [
            ("shadows", image { x, _ in x < 64 ? 0.05 : 0.15 }, 0.15, { $0.shadows = $1 }, true),
            ("midtones", image { x, _ in x < 64 ? 0.45 : 0.55 }, 0.55, { $0.midtones = $1 }, true),
            ("highlights", image { x, _ in x < 64 ? 1.1 : 1.3 }, 1.3, { $0.highlights = $1 }, false),
        ]
        for (name, source, base, setOffset, increasesContrast) in cases {
            var p = SpatialFinishingParameters()
            p.clarity = 0
            var offsets = ClarityOffsets()
            setOffset(&offsets, increasesContrast ? 0.5 : -0.5)
            p.clarityOffsets = offsets
            let actual = pixel(try renderer.apply(p, to: source), 66, 64)
            if increasesContrast {
                XCTAssertGreaterThan(actual, base + 1e-3, "positive \(name) offset should strengthen the edge at total zero")
            } else {
                XCTAssertLessThan(actual, base - 1e-3, "negative \(name) offset should soften the edge at total zero")
            }
        }
    }

    func testClarityOffsetsCombineWithTotalAndClampPerPixelAction() throws {
        let source = image { x, _ in x < 64 ? 1.1 : 1.3 }
        var crossedZero = SpatialFinishingParameters()
        crossedZero.clarity = -0.4
        crossedZero.clarityOffsets = ClarityOffsets(highlights: 0.6)
        XCTAssertGreaterThan(pixel(try renderer.apply(crossedZero, to: source), 66, 64), 1.3,
                             "a positive highlight offset can cross a negative total through zero")

        var overPositive = SpatialFinishingParameters()
        overPositive.clarity = 0.8
        overPositive.clarityOffsets = ClarityOffsets(highlights: 0.7)
        var positiveLimit = SpatialFinishingParameters()
        positiveLimit.clarity = 1
        XCTAssertEqual(pixel(try renderer.apply(overPositive, to: source), 66, 64),
                       pixel(try renderer.apply(positiveLimit, to: source), 66, 64), accuracy: 1e-5,
                       "combined action is limited to +1")

        var overNegative = SpatialFinishingParameters()
        overNegative.clarity = -0.8
        overNegative.clarityOffsets = ClarityOffsets(highlights: -0.7)
        var negativeLimit = SpatialFinishingParameters()
        negativeLimit.clarity = -1
        XCTAssertEqual(pixel(try renderer.apply(overNegative, to: source), 66, 64),
                       pixel(try renderer.apply(negativeLimit, to: source), 66, 64), accuracy: 1e-5,
                       "combined action is limited to −1")
    }

    func testOffsetOnlyClarityIsActiveButZeroOffsetsStayNeutral() throws {
        let source = image { x, _ in x < 64 ? 0.85 : 0.95 }
        var offsetsOnly = SpatialFinishingParameters()
        offsetsOnly.clarityOffsets = ClarityOffsets(highlights: -0.5)
        XCTAssertFalse(offsetsOnly.isNeutral)
        XCTAssertGreaterThan(renderer.sampleMargin(offsetsOnly, extent: source.extent), 0)
        XCTAssertNotEqual(pixel(try renderer.apply(offsetsOnly, to: source), 66, 64), 0.95)

        var zero = SpatialFinishingParameters()
        zero.clarityOffsets = ClarityOffsets()
        XCTAssertTrue(zero.isNeutral)
        XCTAssertTrue(try renderer.apply(zero, to: source) === source)
    }

    /// 舊倍率三區都是 1 時，三區權重加總為 1，和新版三區 0 的結果相同；第一次拉分區滑桿時畫面不會跳。
    func testDefaultLegacyTonesMatchZeroOffsets() throws {
        for (source, x) in [(image { x, _ in x < 64 ? 0.05 : 0.15 }, 66), (image { x, _ in x < 64 ? 0.45 : 0.55 }, 62),
                            (image { x, _ in x < 64 ? 0.85 : 0.95 }, 66)] {
            for total in [-0.7, 0.5] {
                var legacy = SpatialFinishingParameters(); legacy.clarity = total
                var offsets = legacy; offsets.clarityOffsets = ClarityOffsets()
                XCTAssertEqual(pixel(try renderer.apply(legacy, to: source), x, 64),
                               pixel(try renderer.apply(offsets, to: source), x, 64), accuracy: 1e-4)
            }
        }
    }

    /// 紋理的半徑比清晰度小，所以離邊界稍遠的位置幾乎不受影響。
    func testTextureActsOnSmallerRadiusThanClarity() throws {
        let source = image { x, _ in x < 64 ? 0.3 : 0.7 }
        var texture = SpatialFinishingParameters(); texture.texture = 1.0
        var clarity = SpatialFinishingParameters(); clarity.clarity = 1.0
        let far = 60
        let dTexture = abs(pixel(try renderer.apply(texture, to: source), far, 64) - 0.3)
        let dClarity = abs(pixel(try renderer.apply(clarity, to: source), far, 64) - 0.3)
        XCTAssertLessThan(dTexture, dClarity)
    }

    func testGlowSpreadsHighlightIntoNeighbourhood() throws {
        let source = image { x, y in
            let dx = Double(x - 64), dy = Double(y - 64)
            return sqrt(dx * dx + dy * dy) < 6 ? 1.0 : 0.1
        }
        var p = SpatialFinishingParameters()
        p.glow.amount = 1.0
        p.glow.radius = 0.5
        p.glow.threshold = 0.5
        let out = try renderer.apply(p, to: source)
        XCTAssertGreaterThan(pixel(out, 78, 64), 0.1 + 1e-3, "亮斑旁應被照亮")
        XCTAssertEqual(pixel(out, 4, 4), 0.1, accuracy: 5e-3, "遠處幾乎不受影響")
    }

    /// 霧是低頻的白色veil，細節疊在上面。去霧把 veil 扣掉，細節的對比就被放大。
    func testDehazeRemovesVeilAndExpandsContrast() throws {
        let source = image { x, _ in x % 8 < 4 ? 0.55 : 0.60 }
        var p = SpatialFinishingParameters()
        p.dehaze = 1.0
        let out = try renderer.apply(p, to: source)
        let low = pixel(out, 65, 64)
        let high = pixel(out, 69, 64)
        XCTAssertLessThan(low, 0.55, "霧被扣掉後暗部應更暗")
        XCTAssertGreaterThan(high - low, 0.05 + 1e-3, "細節對比應被放大")
    }

    func testNegativeDehazeAddsHaze() throws {
        let source = image { x, _ in Double(x) / 127.0 }
        var p = SpatialFinishingParameters()
        p.dehaze = -1.0
        let out = try renderer.apply(p, to: source)
        XCTAssertGreaterThan(pixel(out, 4, 64), 4.0 / 127.0, "加霧應把暗部墊高")
    }

    /// 銳化半徑也依短邊比例換算，所以要夠大的影像才量得到。
    func testSharpeningChangesEdgeWithoutTouchingFlatArea() throws {
        let size = 512
        let source = image(size: size) { x, _ in x < size / 2 ? 0.3 : 0.7 }
        var p = SpatialFinishingParameters()
        p.sharpening.amount = 1.0
        p.sharpening.radius = 1.0
        let out = try renderer.apply(p, to: source)
        XCTAssertGreaterThan(abs(pixel(out, size / 2 - 1, size / 2) - 0.3), 1e-3)
        XCTAssertEqual(pixel(out, 8, size / 2), 0.3, accuracy: 5e-3)
    }

    /// 半徑以短邊比例計算，所以縮圖預覽與全解析度輸出的效果位置一致。
    func testRadiiScaleWithImageSize() throws {
        var p = SpatialFinishingParameters()
        p.clarity = 1.0
        func edgeDelta(_ size: Int) throws -> Double {
            let src = image(size: size) { x, _ in x < size / 2 ? 0.3 : 0.7 }
            let out = try renderer.apply(p, to: src)
            return pixel(out, size / 2 - 1, size / 2) - 0.3
        }
        let small = try edgeDelta(128)
        let large = try edgeDelta(256)
        XCTAssertEqual(small, large, accuracy: 0.02)
    }
}
