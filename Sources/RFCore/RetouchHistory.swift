import Foundation
import CoreImage

/// 重編輯時先完成全部計算才交回新的陣列；呼叫端一次提交，失敗不改歷史。
public enum RetouchHistory {
    public static func makePatch(image: CIImage, recipe: RetouchRecipe, rawURL: URL,
                                 context: CIContext,
                                 aiFill: (@Sendable (CIImage, CIImage) throws -> CIImage)? = nil) throws -> RetouchPatch {
        try Task.checkCancellation()
        var recipe = recipe
        let mask = try recipe.brushMask(extent: image.extent)
        let pixels: CIImage
        if !mask.bytes.contains(where: { $0 > 0 }) {
            pixels = CIImage(color: .clear).cropped(to: mask.bounds)
        } else if recipe.mode == .remove {
            guard !recipe.useAI || aiFill != nil else { throw RetouchError.cannotCreatePatch }
            pixels = try RetouchEngine.makePatch(image: image, brushMask: mask, context: context,
                                                 aiFill: recipe.useAI ? aiFill : nil)
        } else {
            guard !recipe.useAI else { throw RetouchError.invalidStroke }
            if recipe.source == nil {
                recipe.sourceCandidates = try RetouchSourceHeal.candidates(image: image, mask: mask, context: context)
                guard let source = recipe.sourceCandidates.first else { throw RetouchError.noCleanSource }
                recipe.source = source
            }
            guard let source = recipe.source else { throw RetouchError.sourceOutsideImage }
            pixels = try RetouchSourceHeal.makePatch(image: image, mask: mask, source: source,
                                                     heal: recipe.mode == .heal, context: context)
        }
        try Task.checkCancellation()
        var saved = try RetouchAssetStore.write(patch: pixels, imageExtent: image.extent, forRaw: rawURL,
                                                context: context,
                                                modelRevision: recipe.useAI ? RetouchAIModel.revision : nil)
        saved.recipe = recipe
        try Task.checkCancellation()
        return saved
    }

    /// image 為無修補的光學校正基底。生成與舊結果保留像素並提示檢視，不重跑模型。
    public static func rebuilding(_ patches: [RetouchPatch], startingAt index: Int,
                                  replacement: RetouchRecipe? = nil, deleting: Bool = false,
                                  image: CIImage, optical: OpticalParameters,
                                  rawURL: URL, context: CIContext) throws -> [RetouchPatch] {
        guard patches.indices.contains(index) else { throw RetouchError.invalidStroke }
        if !deleting {
            guard let replacement, replacement.canEditSource,
                  replacement.matchesOpticalBase(optical) else { throw RetouchError.invalidStroke }
        }
        var result = Array(patches.prefix(index))
        var base = try RetouchAssetStore.applying(RetouchParameters(patches: result).applicable(to: optical), to: image, forRaw: rawURL)
        for position in index..<patches.count {
            try Task.checkCancellation()
            if position == index && deleting { continue }
            var patch = patches[position]
            let recipe = position == index ? replacement : patch.recipe
            if let recipe, recipe.version == 2, !recipe.useAI, recipe.matchesOpticalBase(optical) {
                patch = try makePatch(image: base, recipe: recipe, rawURL: rawURL, context: context)
            } else {
                patch.needsReview = true
            }
            result.append(patch)
            base = try RetouchAssetStore.applying(RetouchParameters(patches: [patch]).applicable(to: optical), to: base, forRaw: rawURL)
        }
        return result
    }
}
