import XCTest
import CoreImage
@testable import RFCore

final class ReconstructionBoundaryTests: XCTestCase {
    func testReconstructionBoundaryPreservesSceneHeadroomAndBothTargets() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let pipeline = try RenderPipeline(gpu: gpu)
        var parameters = EditParameters()
        parameters.optical.enabled = false
        parameters.colorEngine.enabled = false
        let image = CIImage(color: CIColor(red: 2, green: 2, blue: 2))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let decoded = DecodedRaw(url: URL(fileURLWithPath: "/synthetic.dng"), image: image,
                                 metadata: RawMetadata(), fullSize: image.extent.size,
                                 colorSpace: gpu.workingColorSpace)

        let legacy = try pipeline.makeSceneMaster(decoded: decoded, parameters: parameters)
        let sceneLinear = try pipeline.reconstruct(decoded: decoded, parameters: parameters)
        let staged = pipeline.makeSceneMaster(sceneLinear: sceneLinear, parameters: parameters)
        XCTAssertEqual(sceneLinear.scale, 1)
        XCTAssertEqual(sceneLinear.image.extent, legacy.image.extent)

        let scene = try pipeline.renderSceneLinear(sceneMaster: staged, parameters: parameters)
        XCTAssertGreaterThan(sample(scene, context: gpu.ciContext,
                                    colorSpace: gpu.workingColorSpace), 1)

        for target in [RenderingTarget.preset(.appleSDR),
                       RenderingTarget.preset(.hdrStandard)] {
            let space = RenderPipeline.colorSpace(for: target)
            let oldOutput = try pipeline.render(sceneMaster: legacy, parameters: parameters,
                                                target: target)
            let newOutput = try pipeline.render(sceneMaster: staged, parameters: parameters,
                                                target: target)
            XCTAssertEqual(sample(oldOutput, context: gpu.ciContext, colorSpace: space),
                           sample(newOutput, context: gpu.ciContext, colorSpace: space),
                           accuracy: 0.0001)
        }
    }

    private func sample(_ image: CIImage, context: CIContext,
                        colorSpace: CGColorSpace) -> Double {
        var pixel = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 16,
                       bounds: CGRect(x: 3, y: 3, width: 1, height: 1),
                       format: .RGBAf, colorSpace: colorSpace)
        return Double(pixel[0])
    }
}
