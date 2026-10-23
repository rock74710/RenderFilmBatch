import Foundation
import Metal
import CoreImage
import simd

/// 與 `OpticalCorrection.metal` 中 `OpticalParams` 對應的結構。欄位順序必須一致。
struct OpticalParamsGPU {
    var distortionKind: Int32 = 0
    var da: Float = 0
    var db: Float = 0
    var dc: Float = 0

    var tcaKind: Int32 = 0
    var kr: Float = 1
    var kb: Float = 1
    var br: Float = 0
    var bb: Float = 0

    var vignKind: Int32 = 0
    var vk1: Float = 0
    var vk2: Float = 0
    var vk3: Float = 0

    var center: SIMD2<Float> = .zero
    var invHalfDiag: Float = 1
}

/// §2.3 Optical Renderer。處理順序固定為「早期暗角 → 後期 TCA + 幾何畸變」。
public final class OpticalRenderer: @unchecked Sendable {
    private let gpu: GPUContext
    private let vignettePipeline: MTLComputePipelineState
    private let geometryPipeline: MTLComputePipelineState

    public init(gpu: GPUContext) throws {
        self.gpu = gpu
        self.vignettePipeline = try gpu.makePipeline(function: "rf_vignetting")
        self.geometryPipeline = try gpu.makePipeline(function: "rf_geometry")
    }

    /// 對 CIImage 套用光學校正。profile 無內容時原樣回傳，不浪費一次 GPU pass。
    public func apply(to image: CIImage, profile: ResolvedLensProfile) throws -> CIImage {
        try apply(to: image, profile: profile) { width, height in
            try gpu.makeTexture(width: width, height: height, usage: [.shaderRead, .shaderWrite])
        }
    }

    // 注入配置入口，讓測試能核對實際 texture 數量，不把 GPU 記憶體估值當實測。
    func apply(to image: CIImage, profile: ResolvedLensProfile,
               allocateTexture: (Int, Int) throws -> MTLTexture) throws -> CIImage {
        let performanceInterval = RFPerformance.begin("OpticalSynchronous")
        defer { RFPerformance.end("OpticalSynchronous", performanceInterval) }
        guard !profile.isIdentity else { return image }

        let extent = image.extent.isInfinite ? CGRect(x: 0, y: 0, width: 2048, height: 2048) : image.extent
        let w = Int(extent.width.rounded()), h = Int(extent.height.rounded())
        guard w > 0, h > 0 else { return image }

        var params = OpticalParamsGPU()
        switch profile.distortion.kind {
        case .none: params.distortionKind = 0
        case .poly3: params.distortionKind = 1
        case .poly5: params.distortionKind = 2
        case .ptlens: params.distortionKind = 3
        }
        params.da = Float(profile.distortion.a)
        params.db = Float(profile.distortion.b)
        params.dc = Float(profile.distortion.c)

        switch profile.tca.kind {
        case .none: params.tcaKind = 0
        case .linear: params.tcaKind = 1
        case .poly3: params.tcaKind = 2
        }
        params.kr = Float(profile.tca.kr)
        params.kb = Float(profile.tca.kb)
        params.br = Float(profile.tca.br)
        params.bb = Float(profile.tca.bb)

        params.vignKind = profile.vignetting.kind == .pa ? 1 : 0
        params.vk1 = Float(profile.vignetting.k1)
        params.vk2 = Float(profile.vignetting.k2)
        params.vk3 = Float(profile.vignetting.k3)

        params.center = SIMD2(Float(w) / 2, Float(h) / 2)
        let halfDiag = sqrt(Double(w * w + h * h)) / 2
        params.invHalfDiag = Float(1.0 / halfDiag)

        let source = try allocateTexture(w, h)

        guard let buffer = gpu.commandQueue.makeCommandBuffer() else { return image }

        // Core Image 直接把解碼結果畫進 Metal texture，之後全程留在 GPU。
        gpu.ciContext.render(
            image.transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                                    y: -extent.origin.y)),
            to: source,
            commandBuffer: buffer,
            bounds: CGRect(x: 0, y: 0, width: w, height: h),
            colorSpace: gpu.workingColorSpace
        )

        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)

        var vignetteInput = source
        if params.vignKind != 0 {
            let mid = try allocateTexture(w, h)
            guard let enc = buffer.makeComputeCommandEncoder() else { return image }
            enc.setComputePipelineState(vignettePipeline)
            enc.setTexture(source, index: 0)
            enc.setTexture(mid, index: 1)
            enc.setBytes(&params, length: MemoryLayout<OpticalParamsGPU>.stride, index: 0)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            enc.endEncoding()
            vignetteInput = mid
        }

        var output = vignetteInput
        if params.distortionKind != 0 || params.tcaKind != 0 {
            let dest = try allocateTexture(w, h)
            guard let enc = buffer.makeComputeCommandEncoder() else { return image }
            enc.setComputePipelineState(geometryPipeline)
            enc.setTexture(vignetteInput, index: 0)
            enc.setTexture(dest, index: 1)
            enc.setBytes(&params, length: MemoryLayout<OpticalParamsGPU>.stride, index: 0)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            enc.endEncoding()
            output = dest
        }

        buffer.commit()
        buffer.waitUntilCompleted()

        guard let wrapped = CIImage(
            mtlTexture: output,
            options: [.colorSpace: gpu.workingColorSpace]
        ) else { return image }

        // `CIContext.render(to:)` 與 `CIImage(mtlTexture:)` 用的是同一套 y 軸方向，
        // 一進一出已經抵銷，這裡再翻一次會讓畫面上下顛倒（A-003）。只要移回原點。
        return wrapped.transformed(by: CGAffineTransform(translationX: extent.origin.x,
                                                         y: extent.origin.y))
    }
}
