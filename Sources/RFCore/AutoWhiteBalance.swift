import Foundation
import CoreImage
import simd

/// Estimates a restrained correction to the camera-balanced RAW image.
/// It uses near-neutral scene pixels and leaves the camera setting unchanged when
/// the scene does not contain enough reliable neutral evidence.
public enum AutoWhiteBalance {
    public struct Result: Equatable, Sendable {
        public let gains: SIMD3<Double>
        public let neutralPixelCount: Int
        public let usedFallback: Bool
    }

    public static func analyze(_ image: CIImage, context: CIContext) -> Result {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0,
              extent.width.isFinite, extent.height.isFinite else {
            return Result(gains: SIMD3(repeating: 1), neutralPixelCount: 0, usedFallback: true)
        }
        let scale = min(1, 512 / max(extent.width, extent.height))
        let width = max(1, Int(ceil(extent.width * scale)))
        let height = max(1, Int(ceil(extent.height * scale)))
        let normalized = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(normalized, toBitmap: bytes.baseAddress!,
                           rowBytes: width * 4 * MemoryLayout<Float>.size,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!)
        }
        return analyzeRGBA(pixels)
    }

    /// RGBA float samples in linear Rec.2020. Exposed for deterministic tests.
    public static func analyzeRGBA(_ pixels: [Float]) -> Result {
        var sum = SIMD3<Double>(repeating: 0)
        var count = 0
        let total = pixels.count / 4
        for index in stride(from: 0, to: total * 4, by: 4) {
            let r = Double(pixels[index])
            let g = Double(pixels[index + 1])
            let b = Double(pixels[index + 2])
            let a = Double(pixels[index + 3])
            guard r.isFinite, g.isFinite, b.isFinite, a.isFinite, a > 0 else { continue }
            let maximum = max(r, g, b)
            let minimum = min(r, g, b)
            guard maximum > 0.03, maximum < 0.9, minimum > 0,
                  (maximum - minimum) / maximum < 0.3 else { continue }
            sum += SIMD3(r, g, b)
            count += 1
        }
        guard count >= max(16, total / 100) else {
            return Result(gains: SIMD3(repeating: 1), neutralPixelCount: count, usedFallback: true)
        }
        let mean = sum / Double(count)
        let gains = SIMD3(
            min(max(mean.y / mean.x, 0.8), 1.25),
            1,
            min(max(mean.y / mean.z, 0.8), 1.25)
        )
        return Result(gains: gains, neutralPixelCount: count, usedFallback: false)
    }

    /// Finds the Temperature + Tint pair whose existing renderer most closely matches
    /// an Auto correction. These values let a manual edit continue from Auto without
    /// adding fields to the sidecar format.
    public static func whiteBalanceValues(
        matching gains: SIMD3<Double>, asShot: WhiteBalanceValues
    ) -> WhiteBalanceValues {
        let targetRed = gains.x.isFinite ? min(max(gains.x, 0.05), 20) : 1
        let targetBlue = gains.z.isFinite ? min(max(gains.z, 0.05), 20) : 1
        var bestTemperature = 6500.0
        var bestTint = 0.0
        var bestScore = Double.infinity

        func score(temperature: Double, tint: Double) -> Double {
            let candidate = SceneNormalization.whiteBalanceGains(
                temperature: temperature, tint: tint,
                asShotTemperature: asShot.temperature, asShotTint: asShot.tint
            )
            let redError = log(candidate.x / targetRed)
            let blueError = log(candidate.z / targetBlue)
            return redError * redError + blueError * blueError
        }

        func consider(_ temperature: Double, _ tint: Double) {
            let temperature = min(max(temperature, WhiteBalanceParameters.temperatureRange.lowerBound),
                                  WhiteBalanceParameters.temperatureRange.upperBound)
            let tint = min(max(tint, WhiteBalanceParameters.tintRange.lowerBound),
                           WhiteBalanceParameters.tintRange.upperBound)
            let candidateScore = score(temperature: temperature, tint: tint)
            if candidateScore < bestScore {
                bestScore = candidateScore
                bestTemperature = temperature
                bestTint = tint
            }
        }

        // A small grid finds the neighborhood; progressively smaller grids refine it.
        for temperature in stride(from: 2000.0, through: 12000.0, by: 100) {
            for tintStep in -20...20 {
                consider(temperature, Double(tintStep) * 0.005)
            }
        }
        var temperatureStep = 20.0
        var tintStep = 0.001
        for _ in 0..<3 {
            let centerTemperature = bestTemperature
            let centerTint = bestTint
            for temperatureOffset in -4...4 {
                for tintOffset in -4...4 {
                    consider(centerTemperature + Double(temperatureOffset) * temperatureStep,
                             centerTint + Double(tintOffset) * tintStep)
                }
            }
            temperatureStep /= 5
            tintStep /= 5
        }

        return WhiteBalanceValues(temperature: bestTemperature, tint: bestTint)
    }
}
