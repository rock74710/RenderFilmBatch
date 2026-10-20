import AppKit
import SwiftUI
import RFCore

@main
struct RenderFilmBatchApp: App {
    @NSApplicationDelegateAdaptor(BatchAppDelegate.self) private var delegate
    @StateObject private var model = BatchModel()

    var body: some Scene {
        WindowGroup("RenderFilm Batch") {
            BatchView(model: model)
                .frame(minWidth: 900, minHeight: 640)
        }
    }
}

private final class BatchAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct BatchView: View {
    @ObservedObject var model: BatchModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ScrollView { sidebar.padding(16) }
                    .frame(width: 380)
                    .glassPanel(cornerRadius: 26)
                VStack(spacing: 12) {
                    previewPanel.glassPanel(cornerRadius: 26)
                    FilmstripView(model: model)
                        .frame(height: 124)
                        .glassPanel(cornerRadius: 22)
                }
            }
            footer.glassPanel(cornerRadius: 22)
        }
        .padding(12)
        .background(backdrop)
        .preferredColorScheme(.dark)
    }

    /// 純黑底；不鋪模糊照片，玻璃面板才不會透出照片的倒影。
    private var backdrop: some View {
        Color.black.ignoresSafeArea()
    }

    // MARK: 左側：資料夾、批次調整、批次控制、細節、輸出

    /// 十階強度（1–10）。
    private func levelRow(_ level: Binding<Int>) -> some View {
        LabeledRow(String(localized: "強度")) {
            Slider(value: Binding(get: { Double(level.wrappedValue) },
                                  set: { level.wrappedValue = Int($0.rounded()) }),
                   in: Double(PortraitRetouch.levels.lowerBound)...Double(PortraitRetouch.levels.upperBound),
                   step: 1)
            Text("\(level.wrappedValue)").monospacedDigit().frame(width: 30)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(String(localized: "資料夾"))
            Card {
                folderRow(String(localized: "輸入照片"), text: $model.prefs.inputPath) { model.chooseInput() }
                Text("支援 RAW／JPEG／HEIC；JPEG／HEIC 以 SDR 解碼")
                    .font(.caption2).foregroundStyle(.secondary)
                folderRow(String(localized: "輸出資料夾"), text: $model.prefs.outputPath) { model.chooseOutput() }
            }

            SectionTitle(String(localized: "批次調整")).padding(.top, 8)
            AdjustCard(name: String(localized: "色彩基調")) {
                Picker("", selection: Binding(
                    get: { model.colorBasis },
                    set: { model.selectColorBasis($0) }
                )) {
                    ForEach(ColorBasis.allCases, id: \.self) { basis in
                        Text(basis.displayName).tag(basis)
                    }
                    if model.colorBasis == .existing {
                        Text(ColorBasis.existing.displayName).tag(ColorBasis.existing)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            AdjustCard(name: String(localized: "曲線"), enabled: $model.prefs.curveEnabled) {
                EmptyView()
            } content: {
                curveEditor
            }
            exposureCard
            AdjustCard(name: String(localized: "顆粒")) {
                Menu {
                    Button("關閉") { model.prefs.grain.amount = 0 }
                    ForEach(GrainStrength.allCases, id: \.self) { strength in
                        Button(strength.displayName) { model.prefs.grain.apply(strength) }
                    }
                } label: {
                    Text(model.prefs.grain.isNeutral ? String(localized: "關閉") : model.prefs.grain.strength?.displayName ?? String(localized: "自訂"))
                }
                .accessibilityLabel("顆粒強度")
                .frame(width: 160)
            } content: {
                LabeledRow(String(localized: "大小")) {
                    Slider(value: $model.prefs.grain.size, in: 0...1)
                        .accessibilityLabel("顆粒大小")
                }
                LabeledRow(String(localized: "對比")) {
                    Slider(value: $model.prefs.grain.roughness, in: 0...1)
                        .accessibilityLabel("顆粒對比")
                }
            }
            AdjustCard(name: String(localized: "白平衡"), enabled: $model.prefs.whiteBalanceEnabled) {
                EmptyView()
            } content: {
                HStack(spacing: 8) {
                    ForEach(Self.whiteBalanceChoices, id: \.preset) { choice in
                        Button { model.prefs.whiteBalance = choice.preset } label: {
                            Image(systemName: choice.symbol).frame(width: 30, height: 22)
                        }
                        .buttonStyle(.bordered)
                        .tint(model.prefs.whiteBalance == choice.preset ? .accentColor : nil)
                        .help(choice.name)
                    }
                }
            }

            AdjustCard(name: String(localized: "自動膚色"), enabled: $model.prefs.skinToneEnabled) {
                EmptyView()
            } content: {
                levelRow($model.prefs.skinToneLevel)
            }
            AdjustCard(name: String(localized: "自動柔膚"), enabled: $model.prefs.skinSmoothingEnabled) {
                EmptyView()
            } content: {
                levelRow($model.prefs.skinSmoothingLevel)
            }

            SectionTitle(String(localized: "批次控制")).padding(.top, 8)
            Card {
                SwitchRow(title: String(localized: "逐張自動 EV"), isOn: $model.prefs.automaticExposure)
                Divider().padding(.vertical, 4)
                SwitchRow(title: String(localized: "場景測光"), isOn: $model.prefs.sceneAwareExposure)
                    .disabled(!model.prefs.automaticExposure)
                    .opacity(model.prefs.automaticExposure ? 1 : 0.4)
                SwitchRow(title: String(localized: "相似照片統一 EV"), isOn: $model.prefs.smoothExposure)
                    .disabled(!model.prefs.automaticExposure)
                    .opacity(model.prefs.automaticExposure ? 1 : 0.4)
                Divider().padding(.vertical, 4)
                SwitchRow(title: String(localized: "自動水平"), isOn: $model.prefs.automaticStraighten)
                    .help("偵測地平線並拉直（±\(Int(AutoStraighten.maxDegrees))° 內），旋轉後裁掉黑邊")
                Divider().padding(.vertical, 4)
                SwitchRow(title: String(localized: "略過已存在的輸出"), isOn: $model.prefs.skipExisting)
            }

            SectionTitle(String(localized: "細節")).padding(.top, 8)
            Card {
                SwitchRow(title: String(localized: "RAW 降噪"), isOn: $model.prefs.noiseReduction)
                    .help("只套用於 RAW；JPEG／HEIC 不使用 RAW 降噪。RAW 9 機型使用 ML 降噪。")
                LabeledRow(String(localized: "強度")) {
                    Slider(value: $model.prefs.noiseStrength, in: 0...100)
                    Text("\(Int(model.prefs.noiseStrength))").monospacedDigit().frame(width: 30)
                }
                .disabled(!model.prefs.noiseReduction)
                .opacity(model.prefs.noiseReduction ? 1 : 0.35)
            }

            SectionTitle(String(localized: "輸出")).padding(.top, 8)
            Card {
                LabeledRow(String(localized: "格式")) {
                    Picker("", selection: $model.prefs.format) {
                        Text("TIFF").tag(BatchExportSettings.FileFormat.tiff)
                        Text("HEIC").tag(BatchExportSettings.FileFormat.heic)
                        Text("JPEG").tag(BatchExportSettings.FileFormat.jpeg)
                        Text("PNG").tag(BatchExportSettings.FileFormat.png)
                    }
                    .labelsHidden()
                }
                if model.prefs.format.usesQuality {
                    LabeledRow(String(localized: "品質")) {
                        Slider(value: $model.prefs.quality, in: 50...100, step: 1)
                        Text("\(Int(model.prefs.quality))").monospacedDigit().frame(width: 30)
                    }
                }
                LabeledRow(String(localized: "位元深度")) {
                    Text(bitDepthText).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider().padding(.vertical, 4)
                SwitchRow(title: String(localized: "HDR 輸出"), isOn: $model.prefs.hdr)
                    .disabled(!model.prefs.format.supportsHDR)
                    .opacity(model.prefs.format.supportsHDR ? 1 : 0.4)
                LabeledRow(String(localized: "HDR 編碼")) {
                    Picker("", selection: $model.prefs.hdrTransfer) {
                        Text("Rec.2020 PQ").tag(RenderingTarget.TransferFunction.pq)
                        Text("Rec.2020 HLG").tag(RenderingTarget.TransferFunction.hlg)
                    }
                    .labelsHidden()
                }
                .disabled(!model.prefs.hdr || model.prefs.format != .heic && model.prefs.format != .tiff)
                .opacity(model.prefs.hdr && model.prefs.format.supportsHDR ? 1 : 0.35)
                Divider().padding(.vertical, 4)
                LabeledRow(String(localized: "同時處理")) {
                    Stepper("\(model.effectiveConcurrency) 張", value: $model.prefs.concurrency, in: 1...3)
                        .disabled(model.prefs.superResolution)
                }
            }

            SectionTitle(String(localized: "輸出尺寸")).padding(.top, 8)
            Card {
                LabeledRow(String(localized: "模式")) {
                    Picker("", selection: $model.prefs.sizeMode) {
                        Text("原始尺寸").tag(BatchModel.SizeMode.original)
                        Text("長邊像素").tag(BatchModel.SizeMode.longEdge)
                        Text("百分比").tag(BatchModel.SizeMode.percent)
                    }
                    .labelsHidden()
                }
                if model.prefs.sizeMode == .longEdge {
                    LabeledRow(String(localized: "長邊 px")) {
                        TextField("", value: $model.prefs.longEdgePixels, format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                } else if model.prefs.sizeMode == .percent {
                    LabeledRow(String(localized: "比例 %")) {
                        TextField("", value: $model.prefs.sizePercent, format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Divider().padding(.vertical, 4)
                SwitchRow(title: String(localized: "ML 超解析度"), isOn: $model.prefs.superResolution)
            }
        }
        .disabled(model.isRunning)
    }

    private static let whiteBalanceChoices: [(preset: WhiteBalancePreset, symbol: String, name: String)] = [
        (.auto, "sparkles", String(localized: "ML 逐張自動")),
        (.daylight, "sun.max", String(localized: "日光")),
        (.cloudy, "cloud", String(localized: "陰天")),
        (.tungsten, "lightbulb", String(localized: "鎢絲燈")),
        (.fluorescent, "light.panel", String(localized: "螢光燈")),
    ]

    private var exposureCard: some View {
        let compensation = model.previewExposureCompensation
        let selectedCount = model.selectedFiles.filter { $0 != model.referenceFile }.count
        let hasPreviewExposure = model.previewFile.map { model.exposures[$0] != nil } ?? false
        return Card {
            HStack {
                Text("曝光補償").font(.body.weight(.semibold))
                Spacer()
                Text(String(format: "%+.2f EV", compensation))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            LabeledRow(String(localized: "目前照片")) {
                Slider(value: Binding(get: { model.previewExposureCompensation },
                                      set: { model.setPreviewExposureCompensation($0) }),
                       in: BatchExposureAdjustment.compensationRange, step: 0.05)
                    .disabled(model.previewFile == nil)
                    .accessibilityLabel("目前照片曝光補償")
            }
            HStack(spacing: 8) {
                Button("重置曝光") { model.resetPreviewExposure() }
                    .disabled(!hasPreviewExposure)
                Button("設為亮度參考") { model.setReferenceToPreview() }
                    .disabled(model.previewFile == nil)
            }
            HStack(spacing: 6) {
                Text("亮度參考")
                Text(model.referenceFile?.lastPathComponent ?? String(localized: "尚未設定"))
                    .foregroundStyle(model.referenceFile == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .font(.caption)
            HStack(spacing: 8) {
                Button("匹配選取（\(selectedCount) 張）") { model.matchSelectedExposure() }
                    .disabled(model.isMatchingExposure || model.referenceFile == nil || selectedCount == 0)
                Button("匹配全部（\(max(model.inputFiles.count - (model.referenceFile == nil ? 0 : 1), 0)) 張）") {
                    model.matchAllExposure()
                }
                .disabled(model.isMatchingExposure || model.referenceFile == nil || model.inputFiles.count < 2)
            }
            if model.isMatchingExposure {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.exposureMatchProgress).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("取消匹配") { model.cancelExposureMatch() }
                }
            } else if model.canUndoExposureMatch {
                HStack {
                    Text(model.exposureMatchProgress).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("復原上次匹配") { model.undoLastExposureMatch() }
                }
            }
            if !model.exposureMatchResult.isEmpty {
                ScrollView {
                    Text(model.exposureMatchResult)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 104)
            }
            if model.prefs.hdr && model.prefs.format.supportsHDR {
                Text("HDR 照片會以 SDR 預覽亮度匹配。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 曲線

    private var curveEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("", selection: $model.previewCurve.mode) {
                    Text("一般").tag(BatchCurve.Mode.luma)
                    Text("RGB").tag(BatchCurve.Mode.rgb)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if model.previewCurve.mode == .rgb {
                    Picker("", selection: $model.prefs.curveChannel) {
                        Text("R").tag(BatchModel.CurveChannel.red)
                        Text("G").tag(BatchModel.CurveChannel.green)
                        Text("B").tag(BatchModel.CurveChannel.blue)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Spacer()
                Toggle("自由滑動", isOn: $model.prefs.curveFreeDrag).toggleStyle(.checkbox)
                Button("重置") { curvePoints.wrappedValue = [] }
            }
            BatchCurveView(points: curvePoints, snap: !model.prefs.curveFreeDrag,
                           color: curveColor(model.previewCurve.mode == .luma ? nil : model.prefs.curveChannel),
                           references: curveReferences)
                .frame(height: 240)
            HStack(spacing: 8) {
                Button("複製曲線") { model.copyCurve() }
                Button("貼到選取（\(model.selectedFiles.count) 張）") { model.pasteCurve(to: model.selectedFiles) }
                    .disabled(model.copiedCurve == nil)
                Button("貼到全部") { model.pasteCurve(to: model.inputFiles) }
                    .disabled(model.copiedCurve == nil)
            }
            Text("每張照片各自存在原圖旁的 .rfcurve.xml；底片條 ⌘ 點選加選、⇧ 點選選範圍")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(model.previewFile == nil)
    }

    /// 目前編輯中的曲線：一般模式是合併曲線，RGB 模式是所選通道。
    private var curvePoints: Binding<[Double]> {
        guard model.previewCurve.mode == .rgb else { return $model.previewCurve.luma }
        return curveBinding(model.prefs.curveChannel)
    }

    private func curveBinding(_ channel: BatchModel.CurveChannel) -> Binding<[Double]> {
        switch channel {
        case .red: $model.previewCurve.red
        case .green: $model.previewCurve.green
        case .blue: $model.previewCurve.blue
        }
    }

    private func curveColor(_ channel: BatchModel.CurveChannel?) -> Color {
        switch channel {
        case nil: .white
        case .red: .red
        case .green: .green
        case .blue: .blue
        }
    }

    private var curveReferences: [(points: [Double], color: Color)] {
        guard model.previewCurve.mode == .rgb else { return [] }
        return [BatchModel.CurveChannel.red, .green, .blue]
            .filter { $0 != model.prefs.curveChannel }
            .map { (curveBinding($0).wrappedValue, curveColor($0)) }
    }

    private var bitDepthText: String {
        switch (model.prefs.format, model.prefs.hdr && model.prefs.format.supportsHDR) {
        case (.tiff, true): "16-bit"
        case (.heic, true): "10-bit"
        case (.jpeg, true): "8-bit＋HDR gain map"
        default: "8-bit"
        }
    }

    private func folderRow(_ label: String, text: Binding<String>,
                           choose: @escaping () -> Void) -> some View {
        LabeledRow(label) {
            HStack {
                TextField("", text: text).textFieldStyle(.roundedBorder)
                Button("選取…", action: choose)
            }
        }
    }

    // MARK: 預覽

    private var previewIndex: Int? { model.previewFile.flatMap { model.inputFiles.firstIndex(of: $0) } }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.previewFile?.lastPathComponent ?? String(localized: "預覽")).font(.headline)
                Spacer()
                if let index = previewIndex {
                    Text("\(index + 1) / \(model.inputFiles.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
            ZStack {
                Rectangle().fill(.black.opacity(0.3))
                if let image = model.previewImage {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                } else {
                    Text(model.inputFiles.isEmpty ? String(localized: "選取輸入資料夾後顯示預覽") : "").foregroundStyle(.secondary)
                }
                HStack {
                    navButton("chevron.left", offset: -1)
                    Spacer()
                    navButton("chevron.right", offset: 1)
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            Text(model.previewStatus).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func navButton(_ symbol: String, offset: Int) -> some View {
        Button { model.stepPreview(offset) } label: {
            Image(systemName: symbol).font(.title3.weight(.semibold)).frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: Circle())
        .disabled(model.inputFiles.count < 2)
    }

    // MARK: 底部：進度與動作

    private static func isFailure(_ row: BatchReport.Row) -> Bool {
        if case .failed = row.outcome { return true }
        return false
    }

    private static func describe(_ row: BatchReport.Row) -> String {
        switch row.outcome {
        case .skipped: return String(localized: "\(row.file)：已存在，略過")
        case .failed(let message): return String(localized: "\(row.file)：失敗 \(message)")
        case .exported(let r):
            var parts = [String(format: "EV %+.2f", r.appliedExposureEV)]
            if r.appliedSkyEV != 0 { parts.append(String(format: String(localized: "天空 %+.2f"), r.appliedSkyEV)) }
            if !r.meteringSources.isEmpty { parts.append(String(localized: "測光 ") + r.meteringSources.joined(separator: "+")) }
            if r.automaticWhiteBalanceUsedFallback { parts.append(String(localized: "白平衡退回相機設定")) }
            return "\(row.file) → \(r.outputURL.lastPathComponent)：" + parts.joined(separator: "，")
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(model.completed), total: Double(max(model.total, 1)))
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                if !model.rows.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                                Text(Self.describe(row)).font(.caption.monospacedDigit())
                                    .foregroundStyle(Self.isFailure(row) ? .red : .secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                }
            }
            Button("取消") { model.cancel() }
                .disabled(!model.isRunning)
            Button("開始批次處理") { model.start() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRunning || model.isMatchingExposure)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

// MARK: - 共用元件

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 6)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
    }
}

private struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.callout).frame(width: 74, alignment: .leading)
            content
        }
    }
}

private struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            Text(title).font(.callout.weight(.semibold))
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }
}

/// 調整卡：標題列（名稱、右側控制、可選啟用開關），啟用時才展開下方內容。
private struct AdjustCard<Trailing: View, Content: View>: View {
    let name: String
    var enabled: Binding<Bool>?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(name: String, enabled: Binding<Bool>? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: () -> Content = { EmptyView() }) {
        self.name = name
        self.enabled = enabled
        self.trailing = trailing()
        self.content = content()
    }

    private var isOn: Bool { enabled?.wrappedValue ?? true }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(name).font(.body.weight(.semibold))
                Spacer()
                trailing
                if let enabled {
                    Toggle("", isOn: enabled.animation(.snappy)).toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            if isOn && !(content is EmptyView) {
                Divider().opacity(0.5)
                content
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.10)))
    }
}

extension View {
    /// macOS 26 以後用系統 Liquid Glass，之前的系統退回半透明材質。
    @ViewBuilder func glassPanel(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
