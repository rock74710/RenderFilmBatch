import XCTest
@testable import RFCore

final class ModelPackingProbeTests: XCTestCase {
    /// Run with RF_MODEL_PACK_PROBE=1 to compare the current scalar packing loop
    /// with the production vDSP helper on a full model tile.
    func testModelPackingProbeWhenOptedIn() throws {
        guard ProcessInfo.processInfo.environment["RF_MODEL_PACK_PROBE"] == "1" else {
            throw XCTSkip("Set RF_MODEL_PACK_PROBE=1 to run the model packing probe")
        }

        let warmupCount = 8
        let sampleCount = 31
        let repetitionsPerSample = 3

        for tile in [SuperResolution.tile] {
            let rgba = Self.makeRGBAInput(tile: tile)
            let plane = tile * tile
            var scalarOutput = [Float](repeating: 0, count: plane * 3)
            var candidateOutput = [Float](repeating: 0, count: plane * 3)
            var scalarSamples = [Double]()
            var candidateSamples = [Double]()
            var initialMismatch: (index: Int, scalarBits: UInt32, candidateBits: UInt32)?
            var finalMismatch: (index: Int, scalarBits: UInt32, candidateBits: UInt32)?
            scalarSamples.reserveCapacity(sampleCount)
            candidateSamples.reserveCapacity(sampleCount)

            // Hold raw pointers for the whole probe so the scalar baseline has the
            // same unchecked indexing model as SuperResolution's MLMultiArray pointer.
            rgba.withUnsafeBufferPointer { source in
                scalarOutput.withUnsafeMutableBufferPointer { scalarBuffer in
                    candidateOutput.withUnsafeMutableBufferPointer { candidateBuffer in
                        let input = source.baseAddress!
                        let scalarDestination = scalarBuffer.baseAddress!
                        let candidateDestination = candidateBuffer.baseAddress!
                        Self.scalarPack(input, tile: tile, into: scalarDestination)
                        SuperResolution.packInput(rgba: input, into: candidateDestination)
                        initialMismatch = Self.firstBitwiseMismatch(scalarDestination, candidateDestination,
                                                                    count: plane * 3)

                        // Warm both paths before sampling. Alternate measurement order
                        // to reduce a consistent cache or clock advantage.
                        for _ in 0..<warmupCount {
                            Self.scalarPack(input, tile: tile, into: scalarDestination)
                            SuperResolution.packInput(rgba: input, into: candidateDestination)
                        }
                        for sample in 0..<sampleCount {
                            if sample.isMultiple(of: 2) {
                                scalarSamples.append(Self.measure(repetitions: repetitionsPerSample) {
                                    Self.scalarPack(input, tile: tile, into: scalarDestination)
                                })
                                candidateSamples.append(Self.measure(repetitions: repetitionsPerSample) {
                                    SuperResolution.packInput(rgba: input, into: candidateDestination)
                                })
                            } else {
                                candidateSamples.append(Self.measure(repetitions: repetitionsPerSample) {
                                    SuperResolution.packInput(rgba: input, into: candidateDestination)
                                })
                                scalarSamples.append(Self.measure(repetitions: repetitionsPerSample) {
                                    Self.scalarPack(input, tile: tile, into: scalarDestination)
                                })
                            }
                        }

                        // Leave both buffers containing the final full-tile result.
                        Self.scalarPack(input, tile: tile, into: scalarDestination)
                        SuperResolution.packInput(rgba: input, into: candidateDestination)
                        finalMismatch = Self.firstBitwiseMismatch(scalarDestination, candidateDestination,
                                                                   count: plane * 3)
                    }
                }
            }

            let baselineMedian = Self.median(scalarSamples)
            let candidateMedian = Self.median(candidateSamples)
            let speedup = baselineMedian / candidateMedian
            print("RF_MODEL_PACK_PROBE tile=\(tile) scalar_median_ms=\(Self.milliseconds(baselineMedian)) " +
                  "production_median_ms=\(Self.milliseconds(candidateMedian)) speedup=\(String(format: "%.3f", speedup))x " +
                  "bitwise_equal=\(finalMismatch == nil) samples=\(sampleCount) reps=\(repetitionsPerSample)")
            if let mismatch = finalMismatch ?? initialMismatch {
                print("RF_MODEL_PACK_PROBE_MISMATCH tile=\(tile) index=\(mismatch.index) " +
                      "scalar_bits=0x\(String(mismatch.scalarBits, radix: 16)) " +
                      "candidate_bits=0x\(String(mismatch.candidateBits, radix: 16))")
            }
            XCTAssertNil(finalMismatch, "Production packing must exactly match scalar clamp for all \(tile)² pixels")
        }
    }

    @inline(never)
    private static func scalarPack(_ rgba: UnsafePointer<Float>, tile: Int,
                                   into planar: UnsafeMutablePointer<Float>) {
        let plane = tile * tile
        for i in 0..<plane {
            for c in 0..<3 {
                planar[c * plane + i] = min(max(rgba[i * 4 + c], 0), 1)
            }
        }
    }

    private static func makeRGBAInput(tile: Int) -> [Float] {
        var values = [Float](repeating: 0, count: tile * tile * 4)
        var state: UInt32 = 0x6d2b79f5
        for index in values.indices {
            state = state &* 1_664_525 &+ 1_013_904_223
            let unit = Float(state >> 8) / 16_777_216
            values[index] = unit * 2 - 0.5
        }

        // Exercise the exact edge cases of the scalar min(max(value, 0), 1) expression.
        let edgeValues: [Float] = [
            Float(bitPattern: 0x7fc0_1234), .infinity, -.infinity,
            -0.0, 0.0, 1.0, -1.0, 2.0,
        ]
        for (index, value) in edgeValues.enumerated() {
            values[index * 4] = value
        }
        return values
    }

    private static func firstBitwiseMismatch(_ lhs: UnsafePointer<Float>, _ rhs: UnsafePointer<Float>,
                                             count: Int) -> (index: Int, scalarBits: UInt32, candidateBits: UInt32)? {
        for index in 0..<count where lhs[index].bitPattern != rhs[index].bitPattern {
            return (index, lhs[index].bitPattern, rhs[index].bitPattern)
        }
        return nil
    }

    private static func measure(repetitions: Int, operation: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<repetitions { operation() }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / Double(repetitions)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func milliseconds(_ nanoseconds: Double) -> String {
        String(format: "%.3f", nanoseconds / 1_000_000)
    }
}
