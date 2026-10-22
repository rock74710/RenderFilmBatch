import CoreImage
import Metal
import XCTest
@testable import RFCore

final class OpticalAllocationTests: XCTestCase {
    func testOnlyEnabledPassesAllocateTexturesAndRetainedOutputSurvivesNextRender() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let renderer = try OpticalRenderer(gpu: gpu)
        let origin = CGRect(x: 17, y: -23, width: 64, height: 48)
        let image = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4))
            .cropped(to: origin)
        var retained: [CIImage] = []
        for (vignette, geometry, expected) in [(false, false, 0), (true, false, 2),
                                              (false, true, 2), (true, true, 3)] {
            var allocations = 0
            let profile = ResolvedLensProfile(source: .manual, identifier: "allocation",
                distortion: geometry ? .init(kind: .poly3, a: -0.02) : .none,
                vignetting: vignette ? .init(kind: .pa, k1: -0.3) : .none)
            let output = try renderer.apply(to: image, profile: profile, allocateTexture: { width, height in
                allocations += 1
                return try gpu.makeTexture(width: width, height: height)
            })
            XCTAssertEqual(allocations, expected, "Only active passes need an output texture")
            XCTAssertEqual(output.extent, origin)
            retained.append(output)
        }
        for output in retained {
            let cg = try XCTUnwrap(gpu.ciContext.createCGImage(output, from: origin))
            XCTAssertEqual(cg.width, 64)
            XCTAssertEqual(cg.height, 48)
        }
    }
    func testConcurrentOutputsKeepTheirOwnPixels() async throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let renderer = try OpticalRenderer(gpu: gpu)
        let outputs = try await withThrowingTaskGroup(of: (Double, CIImage).self) { group in
            for index in 1...6 {
                group.addTask {
                    let red = Double(index) / 10
                    let input = CIImage(color: CIColor(red: red, green: 0.2, blue: 0.1,
                                                       colorSpace: gpu.workingColorSpace)!)
                        .cropped(to: CGRect(x: 7, y: 9, width: 32, height: 32))
                    let profile = ResolvedLensProfile(source: .manual, identifier: "parallel",
                        distortion: index.isMultiple(of: 2) ? .init(kind: .poly3, a: -0.02) : .none,
                        vignetting: .init(kind: .pa, k1: -0.1))
                    return (red, try renderer.apply(to: input, profile: profile))
                }
            }
            var images: [(Double, CIImage)] = []
            for try await image in group { images.append(image) }
            return images
        }
        for (red, output) in outputs {
            var pixel = [Float](repeating: 0, count: 4)
            gpu.ciContext.render(output, toBitmap: &pixel, rowBytes: 16,
                bounds: CGRect(x: 23, y: 25, width: 1, height: 1),
                format: .RGBAf, colorSpace: gpu.workingColorSpace)
            XCTAssertEqual(Double(pixel[0]), red, accuracy: 0.003)
        }
    }

}
