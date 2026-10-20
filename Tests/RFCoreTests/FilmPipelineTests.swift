import XCTest
import CoreImage
import simd
@testable import RFCore

/// 實際 GPU 路徑的驗收；合成色卡不能取代真人與底片配對校準。
final class FilmPipelineTests: XCTestCase {
    private var gpu: GPUContext!
    private var pipeline: RenderPipeline!

    override func setUpWithError() throws {
        gpu = try XCTUnwrap(GPUContext.shared, "Film pipeline 驗收需要 Metal")
        pipeline = try RenderPipeline(gpu: gpu)
    }

    private func master(_ p: EditParameters, rgb: SIMD3<Double>) -> SceneMaster {
        let image = CIImage(color: CIColor(red: rgb.x, green: rgb.y, blue: rgb.z,
                                          colorSpace: gpu.workingColorSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        return master(p, image: image)
    }

    private func master(_ p: EditParameters, image: CIImage) -> SceneMaster {
        let metadata = RawMetadata()
        let resolution = pipeline.profileManager.resolve(
            metadata: metadata, preference: .force(.off), manual: nil,
            appleCorrectionSupported: false)
        return pipeline.makeSceneMaster(sceneLinear: SceneLinearImage(
            image: image, metadata: metadata, versions: PipelineVersions(),
            lensResolution: resolution), parameters: p)
    }

    private func pixel(_ image: CIImage, space: CGColorSpace? = nil, x: Int = 8, y: Int = 8) -> SIMD3<Float> {
        var data = [Float](repeating: 0, count: 4)
        gpu.ciContext.render(image, toBitmap: &data, rowBytes: 16,
                             bounds: CGRect(x: x, y: y, width: 1, height: 1),
                             format: .RGBAf, colorSpace: space ?? gpu.workingColorSpace)
        return SIMD3(data[0], data[1], data[2])
    }

    func testMonoPreservesColorMaskSourceAndSceneExportIsNeutral() throws {
        var p = EditParameters()
        p.applyFilmStyle(.monoHard)
        let scene = master(p, rgb: SIMD3(0.8, 0.03, 0.015))
        let source = pixel(try pipeline.maskSource(sceneMaster: scene, parameters: p))
        XCTAssertGreaterThan(source.x - source.y, 0.4)
        var mask = LocalMask(kind: .colorRange)
        mask.hue = 0
        mask.hueWidth = 40
        mask.minimumSaturation = 0.1
        XCTAssertGreaterThan(pixel(try pipeline.maskImage(mask, sceneMaster: scene, parameters: p)).x, 0.5)
        mask.exposureEV = 0.5
        p.localMasks = [mask]
        let exported = pixel(try pipeline.renderSceneLinear(sceneMaster: scene, parameters: p))
        XCTAssertEqual(exported.x, exported.y, accuracy: 0.0005)
        XCTAssertEqual(exported.y, exported.z, accuracy: 0.0005)
    }

    func testMaskedAndDirectRenderingAgreeForEveryStyle() throws {
        for style in FilmStyleID.allCases {
            var p = EditParameters()
            p.applyFilmStyle(style)
            let scene = master(p, rgb: SIMD3(0.42, 0.12, 0.05))
            let space = RenderPipeline.colorSpace(for: p.target)
            let direct = pixel(try pipeline.render(sceneMaster: scene, parameters: p), space: space)
            var nonmatchingMask = LocalMask(kind: .colorRange)
            nonmatchingMask.hue = 120
            nonmatchingMask.hueWidth = 1
            nonmatchingMask.exposureEV = 0.5
            p.localMasks = [nonmatchingMask]
            let masked = pixel(try pipeline.render(sceneMaster: scene, parameters: p), space: space)
            for channel in 0..<3 {
                XCTAssertEqual(direct[channel], masked[channel], accuracy: 0.035, "\(style)")
            }
        }
    }

    func testAmountChangesCachedGPUOutputAndZeroRestoresBaseline() throws {
        let baseline = EditParameters()
        let space = RenderPipeline.colorSpace(for: baseline.target)
        let reference = pixel(try pipeline.render(sceneMaster: master(baseline, rgb: SIMD3(0.5, 0.1, 0.04)),
                                                  parameters: baseline), space: space)
        var p = baseline
        p.applyFilmStyle(.monoHard)
        let full = pixel(try pipeline.render(sceneMaster: master(p, rgb: SIMD3(0.5, 0.1, 0.04)),
                                             parameters: p), space: space)
        XCTAssertEqual(full.x, full.y, accuracy: 0.002)
        p.film.amount = 0
        let restored = pixel(try pipeline.render(sceneMaster: master(p, rgb: SIMD3(0.5, 0.1, 0.04)),
                                                 parameters: p), space: space)
        for channel in 0..<3 { XCTAssertEqual(restored[channel], reference[channel], accuracy: 0.00001) }
        XCTAssertGreaterThan(abs(reference.x - full.x) + abs(reference.y - full.y), 0.05)
    }

    func testFilmChromaByLightnessIsBakedIntoSDRAndHDRLUTs() throws {
        let curve = [1.5, 1.2, 0.95, 0.8, 0.65]
        let neutralCurve = [1.0, 1.0, 1.0, 1.0, 1.0]
        let nodes = ColorEngineParameters.lightnessNodes
        let samples = [
            SIMD3(nodes[0], 0.08, 150.0),
            SIMD3(nodes[2], 0.08, 150.0),
            SIMD3(nodes[4], 0.08, 150.0),
        ]
        let targets: [(RenderingTarget, Bool)] = [
            (RenderingTarget(), false),
            (.edrPreview(gamut: .sRGB, displayHeadroom: 4), true),
        ]

        for (target, isHDR) in targets {
            var styled = try classicCinemaParameters(chromaByLightness: curve)
            var neutral = try classicCinemaParameters(chromaByLightness: neutralCurve)
            styled.target = target
            neutral.target = target
            let outputSpace = isHDR ? RenderPipeline.edrColorSpace(for: target)
                : RenderPipeline.colorSpace(for: target)
            var styledOutputs: [SIMD3<Float>] = []
            var neutralOutputs: [SIMD3<Float>] = []

            for sample in samples {
                let input = RGBColorSpace.workingRec2020.fromXYZ(
                    OKLab.toXYZ(OKLab.fromLCH(sample))
                )
                let styledMaster = master(styled, rgb: input)
                let styledImage = try pipeline.render(
                    sceneMaster: styledMaster, parameters: styled, target: target,
                    outputColorSpace: outputSpace
                )
                let styledPixel = pixel(styledImage, space: outputSpace)
                let cpuStyled = TargetTransform(
                    target: target, tone: styled.toneMapping,
                    gamut: styled.gamutMapping, film: styled.film
                ).apply(styledMaster.sceneTransform.apply(input))
                for channel in 0..<3 {
                    XCTAssertEqual(styledPixel[channel], Float(cpuStyled[channel]), accuracy: 0.035,
                                   "Classic Cinema chroma curve should match the CPU transform, HDR=\(isHDR)")
                }
                styledOutputs.append(styledPixel)

                let neutralMaster = master(neutral, rgb: input)
                let neutralImage = try pipeline.render(
                    sceneMaster: neutralMaster, parameters: neutral, target: target,
                    outputColorSpace: outputSpace
                )
                let neutralPixel = pixel(neutralImage, space: outputSpace)
                let cpuNeutral = TargetTransform(
                    target: target, tone: neutral.toneMapping,
                    gamut: neutral.gamutMapping, film: neutral.film
                ).apply(neutralMaster.sceneTransform.apply(input))
                for channel in 0..<3 {
                    XCTAssertEqual(neutralPixel[channel], Float(cpuNeutral[channel]), accuracy: 0.035,
                                   "neutral chroma curve should match the CPU transform, HDR=\(isHDR)")
                }
                neutralOutputs.append(neutralPixel)
            }

            let darkResponseDistance = simd_length(styledOutputs[0] - neutralOutputs[0])
            XCTAssertGreaterThan(darkResponseDistance, 0.001,
                                 "LUT should include the dark chroma response, HDR=\(isHDR)")

            var zeroAmount = styled
            zeroAmount.film.amount = 0
            var neutralZeroAmount = neutral
            neutralZeroAmount.film.amount = 0
            let input = RGBColorSpace.workingRec2020.fromXYZ(
                OKLab.toXYZ(OKLab.fromLCH(samples[0]))
            )
            let zeroImage = try pipeline.render(
                sceneMaster: master(zeroAmount, rgb: input), parameters: zeroAmount,
                target: target, outputColorSpace: outputSpace
            )
            let neutralZeroImage = try pipeline.render(
                sceneMaster: master(neutralZeroAmount, rgb: input), parameters: neutralZeroAmount,
                target: target, outputColorSpace: outputSpace
            )
            let zeroPixel = pixel(zeroImage, space: outputSpace)
            let neutralZeroPixel = pixel(neutralZeroImage, space: outputSpace)
            for channel in 0..<3 {
                XCTAssertEqual(zeroPixel[channel], neutralZeroPixel[channel], accuracy: 0.0001,
                               "amount zero should bypass the chroma response, HDR=\(isHDR)")
            }
        }
    }

    func testAllStylesRenderSyntheticChartInSDRAndHDR() throws {
        let width = 256, height = 128
        let colors: [SIMD3<Float>] = [SIMD3(0.55, 0.28, 0.18), SIMD3(0.2, 0.36, 0.07),
            SIMD3(0.05, 0.22, 0.65), SIMD3(0.72, 0.04, 0.02), SIMD3(0.55, 0.27, 0.025),
            SIMD3(0.03, 0.38, 0.42), SIMD3(0.4, 0.035, 0.3), SIMD3(0.18, 0.18, 0.18)]
        var data = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = y < height / 2 ? colors[x / 32]
                    : SIMD3<Float>(repeating: Float(0.18 * pow(2, -6 + 10 * Double(x) / Double(width - 1))))
                let offset = (y * width + x) * 4
                data[offset] = color.x; data[offset + 1] = color.y; data[offset + 2] = color.z
            }
        }
        let chart = CIImage(bitmapData: data.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf,
                            colorSpace: gpu.workingColorSpace)
        let output = ProcessInfo.processInfo.environment["RF_FILM_VALIDATION_DIR"]
        if let output { try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true) }
        for style in FilmStyleID.allCases {
            for gamut in RenderingTarget.Gamut.allCases {
                for hdr in [false, true] {
                    var p = EditParameters()
                    p.applyFilmStyle(style)
                    p.target.gamut = gamut
                    if hdr { p.target = .edrPreview(gamut: gamut, displayHeadroom: 4) }
                    let space = hdr ? RenderPipeline.edrColorSpace(for: p.target)
                        : RenderPipeline.colorSpace(for: p.target)
                    let rendered = try pipeline.render(sceneMaster: master(p, image: chart),
                                                       parameters: p, outputColorSpace: space)
                    let value = pixel(rendered, space: space)
                    XCTAssertTrue(value.x.isFinite && value.y.isFinite && value.z.isFinite, "\(style), \(gamut), HDR=\(hdr)")
                    if !hdr && gamut == .sRGB {
                        for (index, color) in colors.enumerated() {
                            let actual = pixel(rendered, space: space, x: index * 32 + 16, y: 96)
                            let isolated = try pipeline.render(sceneMaster: master(p, rgb: SIMD3<Double>(color)),
                                                               parameters: p, outputColorSpace: space)
                            let expected = pixel(isolated, space: space)
                            for channel in 0..<3 {
                                XCTAssertEqual(actual[channel], expected[channel], accuracy: 0.002,
                                               "\(style) patch \(index) channel \(channel)")
                            }
                        }
                    }
                    if !hdr && gamut == .sRGB, let output {
                        try gpu.ciContext.writePNGRepresentation(of: rendered,
                            to: URL(fileURLWithPath: output).appendingPathComponent("\(style.rawValue).png"),
                            format: .RGBA8, colorSpace: space)
                    }
                }
            }
        }
    }

    private func classicCinemaParameters(chromaByLightness: [Double]) throws -> EditParameters {
        var parameters = EditParameters()
        parameters.applyFilmStyle(.classicCinema)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(parameters)) as? [String: Any]
        )
        var film = try XCTUnwrap(object["film"] as? [String: Any])
        var snapshot = try XCTUnwrap(film["profileSnapshot"] as? [String: Any])
        snapshot["chromaByLightness"] = chromaByLightness
        film["profileSnapshot"] = snapshot
        object["film"] = film
        return try JSONDecoder().decode(
            EditParameters.self, from: JSONSerialization.data(withJSONObject: object)
        )
    }
}
