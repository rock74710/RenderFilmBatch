import XCTest
@testable import RFCore

final class SuperResolutionPackingTests: XCTestCase {
    func testPackInputMatchesScalarClampAcrossFullRGBAFloatTile() {
        let tile = SuperResolution.tile
        let plane = tile * tile
        let componentCount = plane * 4
        let outputCount = plane * 3
        let edgeValues: [Float] = [
            Float(bitPattern: 0x7fc0_1234), .infinity, -.infinity,
            -0.0, 0.0, Float.leastNonzeroMagnitude, -Float.leastNonzeroMagnitude,
            0.25, 1.0, -1.0, 2.0, Float.pi, -Float.pi,
        ]
        var rgba = [Float](repeating: 0, count: componentCount)
        for pixel in 0..<plane {
            let offset = pixel * 4
            for channel in 0..<3 {
                rgba[offset + channel] = edgeValues[(pixel * 7 + channel * 3) % edgeValues.count]
            }
            // Alpha has distinct edge values and must not appear in any model plane.
            rgba[offset + 3] = edgeValues[(pixel * 5 + 11) % edgeValues.count]
        }
        var packed = [Float](repeating: 0, count: outputCount)
        var mismatchCount = 0
        var firstMismatch: String?

        rgba.withUnsafeBufferPointer { source in
            packed.withUnsafeMutableBufferPointer { destination in
                let sourcePointer = source.baseAddress!
                let destinationPointer = destination.baseAddress!
                SuperResolution.packInput(rgba: sourcePointer, into: destinationPointer)

                for pixel in 0..<plane {
                    for channel in 0..<3 {
                        let expected = min(max(sourcePointer[pixel * 4 + channel], 0), 1)
                        let outputIndex = channel * plane + pixel
                        let actual = destinationPointer[outputIndex]
                        if expected.bitPattern != actual.bitPattern {
                            mismatchCount += 1
                            if firstMismatch == nil {
                                firstMismatch = "output[\(outputIndex)] source[\(pixel * 4 + channel)] " +
                                    "expected=0x\(String(expected.bitPattern, radix: 16)) " +
                                    "actual=0x\(String(actual.bitPattern, radix: 16))"
                            }
                        }
                    }
                }
            }
        }

        XCTAssertEqual(mismatchCount, 0, "Packed output must match scalar clamp bit for bit. \(firstMismatch ?? "")")
    }
}
