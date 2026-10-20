import Foundation
import CoreImage

/// 將 mapping 前後的 target-linear 影像批次轉成透明診斷覆蓋層。
public final class DiagnosticOverlayRenderer: @unchecked Sendable {
    public enum Failure: Error { case kernel }

    private let kernel: CIColorKernel

    public init() throws {
        guard let kernel = CIColorKernel(source: """
        kernel vec4 diagnosticOverlay(__sample mapped, __sample unmapped,
                                      float mode, float headroom,
                                      float gamutTolerance, float shadowThreshold,
                                      vec3 luma) {
            float alpha = 0.0;
            vec3 color = vec3(0.0);
            float luminance = dot(mapped.rgb, luma);

            if (mode < 1.5) {
                if (luminance > 4.0) { color = vec3(1.0, 0.2, 0.05); alpha = 0.58; }
                else if (luminance > 2.0) { color = vec3(1.0, 0.75, 0.05); alpha = 0.48; }
                else if (luminance > 1.0) { color = vec3(0.1, 0.45, 1.0); alpha = 0.42; }
            } else if (mode < 2.5) {
                if (min(min(unmapped.r, unmapped.g), unmapped.b) < -gamutTolerance) {
                    color = vec3(1.0, 0.0, 1.0); alpha = 0.62;
                }
            } else if (mode < 3.5) {
                if (max(max(mapped.r, mapped.g), mapped.b) >= headroom) {
                    color = vec3(1.0, 0.05, 0.05); alpha = 0.68;
                }
            } else if (mode < 4.5) {
                if (max(max(mapped.r, mapped.g), mapped.b) < shadowThreshold) {
                    color = vec3(0.05, 0.2, 1.0); alpha = 0.68;
                }
            } else {
                float lo = min(min(mapped.r, mapped.g), mapped.b);
                float hi = max(max(mapped.r, mapped.g), mapped.b);
                if (lo < 0.0 || hi > headroom) {
                    color = vec3(1.0, 1.0, 0.0); alpha = 0.62;
                }
            }
            return vec4(color * alpha, alpha);
        }
        """) else { throw Failure.kernel }
        self.kernel = kernel
    }

    public func render(
        mode: DiagnosticOverlayMode,
        mapped: CIImage,
        unmapped: CIImage,
        target: RenderingTarget,
        thresholds: DiagnosticThresholds = DiagnosticThresholds()
    ) throws -> CIImage? {
        guard mode != .off else { return nil }
        let extent = mapped.extent.intersection(unmapped.extent)
        guard !extent.isNull, !extent.isEmpty else { return nil }
        let modeValue: Float
        switch mode {
        case .off: return nil
        case .hdrZones: modeValue = 1
        case .gamutWarning: modeValue = 2
        case .highlightClipping: modeValue = 3
        case .shadowClipping: modeValue = 4
        case .displayRange: modeValue = 5
        }
        let rows = target.gamut.colorSpace.toXYZ.floatRows
        let luma = CIVector(x: CGFloat(rows[3]), y: CGFloat(rows[4]), z: CGFloat(rows[5]))
        guard let result = kernel.apply(extent: extent, arguments: [
            mapped, unmapped, modeValue, Float(target.contentHeadroom),
            Float(thresholds.gamutTolerance), Float(thresholds.shadowThreshold), luma,
        ]) else { throw Failure.kernel }
        return result
    }
}
