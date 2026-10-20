import XCTest
import CoreImage
@testable import RFCore

/// A-109 量測探測：放大看原檔細節的幾種做法各要多久、吃多少記憶體。
/// 只在設定 RF_ZOOM_RAW 時執行；RF_ZOOM_MODE 選做法，每種做法分開跑才量得到各自的記憶體尖峰。
final class ZoomDetailProbe: XCTestCase {
    func testProbe() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["RF_ZOOM_RAW"] else { throw XCTSkip("RF_ZOOM_RAW not set") }
        let mode = env["RF_ZOOM_MODE"] ?? "proxy"
        let gpu = try XCTUnwrap(GPUContext.shared)
        let pipeline = try RenderPipeline(gpu: gpu)
        var t = Date()
        let decoded = try RawDecoder().decode(url: URL(fileURLWithPath: path))
        log("decode", t)

        var p = EditParameters()
        p.spatial.sharpening.amount = 0.5
        p.spatial.grain.amount = 0.3
        p.spatial.clarity = 0.3
        let space = RenderPipeline.colorSpace(for: p.target)
        let ctx = gpu.ciContext
        // 畫面中央一塊視窗大小（Retina 1600×1000 點約 3200×2000 像素）。
        func center(_ e: CGRect) -> CGRect {
            CGRect(x: e.midX - 1600, y: e.midY - 1000, width: 3200, height: 2000).intersection(e)
        }
        var gpuPeak = 0
        func renderOnce(master: SceneMaster, roi: Bool) throws -> CGImage {
            let image = try pipeline.render(sceneMaster: master, parameters: p, outputColorSpace: space)
            let rect = roi ? center(image.extent) : image.extent
            let out = try XCTUnwrap(ctx.createCGImage(image, from: rect, format: .RGBA8, colorSpace: space),
                                    "算圖失敗不能當成快速完成")
            XCTAssertEqual(out.width, Int(rect.width.rounded()))
            gpuPeak = max(gpuPeak, gpu.device.currentAllocatedSize)
            return out
        }
        // 每輪改一次曝光，模擬拖滑桿：LUT 要重烤。第 0 輪是首次（含暖機），之後是一般互動成本。
        func iterate(_ label: String, _ body: () throws -> CGImage) throws {
            for i in 0..<4 {
                p.layerA.exposureEV = 0.1 * Double(i + 1)
                t = Date()
                let img = try body()
                log("\(label)#\(i)\(i == 0 ? "(first)" : "") \(img.width)x\(img.height)", t)
            }
        }

        switch mode {
        case "proxy": // 現況：拖滑桿每次的成本
            try iterate("proxy") {
                try renderOnce(master: pipeline.makeSceneMaster(decoded: decoded, parameters: p, maxDimension: 2048), roi: false)
            }
        case "full": // 做法 1：整張全尺寸重算
            try iterate("full") {
                try renderOnce(master: pipeline.makeSceneMaster(decoded: decoded, parameters: p, maxDimension: nil), roi: false)
            }
        case "roi": // 做法 2：整張圖建好再只取可見範圍
            try iterate("roi") {
                try renderOnce(master: pipeline.makeSceneMaster(decoded: decoded, parameters: p, maxDimension: nil), roi: true)
            }
        case "compare": // 同一塊中央區域：現況 2048 放大 vs 全尺寸，存成 PNG 給人眼比對
            let full = try pipeline.render(sceneMaster: pipeline.makeSceneMaster(decoded: decoded, parameters: p, maxDimension: nil),
                                           parameters: p, outputColorSpace: space)
            let proxy = try pipeline.render(sceneMaster: pipeline.makeSceneMaster(decoded: decoded, parameters: p, maxDimension: 2048),
                                            parameters: p, outputColorSpace: space)
            let k = full.extent.width / proxy.extent.width
            let roi = CGRect(x: full.extent.midX - 600, y: full.extent.midY - 400, width: 1200, height: 800)
            let up = proxy.samplingLinear().transformed(by: CGAffineTransform(scaleX: k, y: k))
            for (name, img) in [("full", full), ("proxy", up)] {
                try ctx.writePNGRepresentation(of: img.cropped(to: roi), to: URL(fileURLWithPath: "/tmp/zoom-\(name).png"),
                                               format: .RGBA8, colorSpace: space)
            }
        default:
            XCTFail("unknown mode \(mode)")
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("ZOOMPROBE \(mode) processPeakRSS=\(usage.ru_maxrss / 1_048_576)MB gpuAllocatedPeak=\(gpuPeak / 1_048_576)MB（RSS 含初始化與解碼，不含全部 GPU private 配置）")
    }

    private func log(_ label: String, _ start: Date) {
        print("ZOOMPROBE \(label) \(Int(Date().timeIntervalSince(start) * 1000))ms")
    }
}
