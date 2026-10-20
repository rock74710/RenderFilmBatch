import AppKit
import Combine
import Foundation
import ImageIO
import RFCore
import UserNotifications

@MainActor
final class BatchModel: ObservableObject {
    enum SizeMode: String, Codable { case original, longEdge, percent }
    enum CurveChannel: String, Codable { case red, green, blue }

    /// 重開 App 時沿用的設定。
    struct Preferences: Codable, Equatable {
        var inputPath = ""
        var outputPath = ""
        var profile: ColorProfile = .natural
        var film = FilmParameters()
        var grain = GrainParameters()
        /// 曲線本身每張照片一份（`curves`），這裡只存開關與編輯方式。
        var curveChannel: CurveChannel = .red
        var curveEnabled = false
        var curveFreeDrag = false
        var automaticExposure = false
        var sceneAwareExposure = true
        var smoothExposure = false
        var automaticStraighten = false
        /// 自動膚色與柔膚各自開關，強度 1–10。
        var skinToneEnabled = false
        var skinToneLevel = 5
        var skinSmoothingEnabled = false
        var skinSmoothingLevel = 5
        /// 關閉時用拍攝設定；開啟時用 `whiteBalance`（逐張自動或固定預設）。
        var whiteBalanceEnabled = false
        var whiteBalance: WhiteBalancePreset = .auto
        var format: BatchExportSettings.FileFormat = .heic
        var quality = 90.0
        var hdr = false
        var hdrTransfer: RenderingTarget.TransferFunction = .pq
        var sizeMode: SizeMode = .original
        var longEdgePixels = 3000
        var sizePercent = 50.0
        var superResolution = false
        var noiseReduction = false
        var noiseStrength = 50.0
        var skipExisting = true
        var concurrency = 2
    }

    private static let preferencesKey = "BatchPreferences"

    /// 舊版存檔缺少的欄位用預設值補上，新增設定時不會整份重置。
    private static func loadPreferences() -> Preferences {
        guard let stored = UserDefaults.standard.data(forKey: preferencesKey),
              let saved = (try? JSONSerialization.jsonObject(with: stored)) as? [String: Any],
              let defaults = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences()))) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(saved) { _, new in new })
        else { return Preferences() }
        var prefs = (try? JSONDecoder().decode(Preferences.self, from: merged)) ?? Preferences()
        if saved["whiteBalanceEnabled"] == nil, prefs.whiteBalance != .asShot { prefs.whiteBalanceEnabled = true }
        if prefs.whiteBalance == .asShot { prefs.whiteBalance = .auto }
        return prefs
    }

    @Published var prefs: Preferences {
        didSet {
            invalidateExposureMatchSnapshot()
            if prefs.inputPath != oldValue.inputPath { reloadInputFiles() }
        }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var isMatchingExposure = false
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var status = String(localized: "選取資料夾並設定參數。")
    @Published private(set) var rows: [BatchReport.Row] = []
    @Published private(set) var inputFiles: [URL] = [] {
        didSet {
            if inputFiles != oldValue {
                invalidateExposureMatchSnapshot()
                lastExposureMatchUndo = nil
                canUndoExposureMatch = false
                loadThumbnails()
                loadCurves()
                loadExposures()
                if let referenceFile, !inputFiles.contains(referenceFile) { self.referenceFile = nil }
            }
        }
    }
    /// 每張照片自己的曲線，存在原圖旁的 XML（`BatchCurve`）；不在字典裡的照片不套曲線。
    @Published var curves: [URL: BatchCurve] = [:] {
        didSet { if curves != oldValue { invalidateExposureMatchSnapshot() } }
    }
    /// 已寫進 XML 的內容，存檔時只寫有變動的照片。
    private var savedCurves: [URL: BatchCurve] = [:]
    /// 底片條縮圖：用 Image I/O 產生，不跑完整渲染。
    @Published private(set) var thumbnails: [URL: CGImage] = [:]
    /// 批次中正在處理的檔案，底片條用來標示「處理中」。
    @Published private(set) var inProgress: Set<URL> = []
    @Published var previewFile: URL? {
        didSet {
            guard previewFile != oldValue else { return }
            invalidateExposureMatchSnapshot()
            // 換來源就停掉舊工作並清空，避免慢的舊預覽蓋掉新照片或殘留在空資料夾。
            previewTask?.cancel()
            previewImage = nil
            previewStatus = ""
        }
    }
    /// 底片條用 ⌘／⇧ 點選多選的照片；目前預覽的照片一定算在選取內。
    @Published private(set) var selection: Set<URL> = [] {
        didSet { if selection != oldValue { invalidateExposureMatchSnapshot() } }
    }
    /// 「複製曲線」存下的曲線，貼上時整份（模式與各通道）取代目標照片的曲線。
    @Published private(set) var copiedCurve: BatchCurve?
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var previewStatus = ""
    /// 單張曝光調整存在各自的 `.rfexposure.json`，不放進曲線 XML。
    @Published var exposures: [URL: BatchExposureAdjustment] = [:] {
        didSet { if exposures != oldValue { invalidateExposureMatchSnapshot() } }
    }
    @Published private(set) var referenceFile: URL? {
        didSet { if referenceFile != oldValue { invalidateExposureMatchSnapshot() } }
    }
    @Published private(set) var exposureMatchProgress = ""
    @Published private(set) var exposureMatchResult = ""
    @Published private(set) var canUndoExposureMatch = false

    private var runTask: Task<Void, Never>?
    private var exposureMatchTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewExporter: BatchExporter?
    private var thumbnailTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var savedExposures: [URL: BatchExposureAdjustment] = [:]
    private var lastExposureMatchUndo: [URL: BatchExposureAdjustment]?
    private var exposureMatchRevision = 0

    init() {
        prefs = Self.loadPreferences()
        reloadInputFiles()
        $prefs.dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] prefs in
                UserDefaults.standard.set(try? JSONEncoder().encode(prefs), forKey: Self.preferencesKey)
                self?.refreshPreview()
            }
            .store(in: &subscriptions)
        $curves.dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveCurves()
                self?.refreshPreview()
            }
            .store(in: &subscriptions)
        $exposures.dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveExposures()
                self?.refreshPreview()
            }
            .store(in: &subscriptions)
        $previewFile.dropFirst().removeDuplicates()
            .sink { [weak self] file in
                // 用方向鍵或換資料夾移到未選取的照片時，選取回到只有這張。
                if let self, let file, !self.selection.contains(file) { self.selection = [file] }
                Task { @MainActor in self?.refreshPreview() }
            }
            .store(in: &subscriptions)
        refreshPreview()
    }

    /// 超解析度很吃記憶體，開啟時一次只處理一張。
    var effectiveConcurrency: Int { prefs.superResolution ? 1 : min(max(prefs.concurrency, 1), 3) }

    func chooseInput() { chooseFolder { prefs.inputPath = $0 } }
    func chooseOutput() { chooseFolder { prefs.outputPath = $0 } }

    private func chooseFolder(_ assign: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { assign(url.path) }
    }

    private func reloadInputFiles() {
        let input = URL(fileURLWithPath: prefs.inputPath, isDirectory: true)
        inputFiles = prefs.inputPath.isEmpty ? [] : ((try? FileManager.default.contentsOfDirectory(
            at: input, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter(BatchExporter.isSupportedInput)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if previewFile.map({ !inputFiles.contains($0) }) ?? true { previewFile = inputFiles.first }
    }

    private func makeSettings(using capturedPreferences: Preferences? = nil) -> BatchExportSettings? {
        let prefs = capturedPreferences ?? self.prefs
        var settings = BatchExportSettings()
        settings.profile = prefs.profile
        settings.film = prefs.film
        settings.grain = prefs.grain
        settings.automaticExposure = prefs.automaticExposure
        settings.sceneAwareExposure = prefs.sceneAwareExposure
        settings.automaticStraighten = prefs.automaticStraighten
        settings.skinToneLevel = prefs.skinToneEnabled ? prefs.skinToneLevel : 0
        settings.skinSmoothingLevel = prefs.skinSmoothingEnabled ? prefs.skinSmoothingLevel : 0
        settings.whiteBalance = !prefs.whiteBalanceEnabled || prefs.whiteBalance == .asShot ? .camera
            : prefs.whiteBalance == .auto ? .automatic : .preset(prefs.whiteBalance)
        settings.format = prefs.format
        settings.quality = min(max(prefs.quality, 1), 100) / 100
        settings.hdr = prefs.hdr
        settings.hdrTransfer = prefs.hdrTransfer
        switch prefs.sizeMode {
        case .original: settings.outputSize = .original
        case .longEdge:
            guard prefs.longEdgePixels > 0 else { status = String(localized: "長邊像素必須大於 0。"); return nil }
            guard prefs.longEdgePixels <= BatchExportSettings.OutputSize.maxLongEdge else {
                status = String(localized: "長邊像素不能超過 \(BatchExportSettings.OutputSize.maxLongEdge)。"); return nil
            }
            settings.outputSize = .longEdge(prefs.longEdgePixels)
        case .percent:
            guard prefs.sizePercent > 0 else { status = String(localized: "百分比必須大於 0。"); return nil }
            settings.outputSize = .percent(prefs.sizePercent)
        }
        settings.superResolution = prefs.superResolution
        settings.noiseReduction = prefs.noiseReduction ? prefs.noiseStrength / 100 : nil
        return settings
    }

    var colorBasis: ColorBasis {
        ColorBasis.selection(profile: prefs.profile, film: prefs.film)
    }

    func selectColorBasis(_ basis: ColorBasis) {
        guard basis != .existing else { return }
        var settings = BatchExportSettings()
        settings.applyColorBasis(basis)
        var next = prefs
        next.profile = settings.profile
        next.film = settings.film
        prefs = next
    }

    /// 某張照片的批次設定：共用設定加上這張自己的曲線。
    private func settings(_ settings: BatchExportSettings, for file: URL,
                         preferences: Preferences? = nil,
                         capturedCurves: [URL: BatchCurve]? = nil,
                         capturedExposures: [URL: BatchExposureAdjustment]? = nil) -> BatchExportSettings {
        var settings = settings
        let preferences = preferences ?? prefs
        let curveMap = capturedCurves ?? curves
        let exposureMap = capturedExposures ?? exposures
        if preferences.curveEnabled, let curve = curveMap[file] { settings.curve = curve.finalCurve }
        let adjustment = exposureMap[file] ?? BatchExposureAdjustment()
        settings.exposureCompensationEV = adjustment.compensationEV
        settings.absoluteExposureEV = adjustment.matchedExposureEV
        return settings
    }

    private func makeExporter() throws -> BatchExporter {
        guard let gpu = GPUContext.shared else { throw ExportError.encodingFailed(String(localized: "無法啟動 GPU")) }
        return BatchExporter(pipeline: try RenderPipeline(gpu: gpu))
    }

    // MARK: 曲線

    /// 目前預覽照片的曲線；編輯的就是這張的 XML。
    var previewCurve: BatchCurve {
        get { previewFile.flatMap { curves[$0] } ?? BatchCurve() }
        set { if let previewFile { curves[previewFile] = newValue } }
    }

    var previewExposureCompensation: Double {
        previewFile.flatMap { exposures[$0]?.compensationEV } ?? 0
    }

    func setPreviewExposureCompensation(_ value: Double) {
        guard let previewFile else { return }
        var adjustment = exposures[previewFile] ?? BatchExposureAdjustment()
        guard value.isFinite else { return }
        adjustment.compensationEV = min(max(value, BatchExposureAdjustment.compensationRange.lowerBound),
                                        BatchExposureAdjustment.compensationRange.upperBound)
        var next = exposures
        if adjustment.isNeutral { next.removeValue(forKey: previewFile) }
        else { next[previewFile] = adjustment }
        exposures = next
    }

    func resetPreviewExposure() {
        guard let previewFile else { return }
        var next = exposures
        next.removeValue(forKey: previewFile)
        exposures = next
    }

    func setReferenceToPreview() {
        guard let previewFile, inputFiles.contains(previewFile) else { return }
        referenceFile = previewFile
        exposureMatchResult = String(localized: "亮度參考：\(previewFile.lastPathComponent)")
    }

    func undoLastExposureMatch() {
        guard let previous = lastExposureMatchUndo else { return }
        var next = exposures
        for (file, adjustment) in previous {
            if adjustment.isNeutral { next.removeValue(forKey: file) }
            else { next[file] = adjustment }
        }
        lastExposureMatchUndo = nil
        canUndoExposureMatch = false
        exposures = next
        exposureMatchResult = String(localized: "已復原上次匹配。")
    }

    /// 目前選取的照片（依底片條順序）。
    var selectedFiles: [URL] { inputFiles.filter { selection.contains($0) || $0 == previewFile } }

    /// 底片條點選：一般點選只選這張並預覽；⌘ 加選或取消（預覽中的照片不能取消）；
    /// ⇧ 選取預覽照片到這張之間的範圍，預覽不變。
    func select(_ file: URL, toggle: Bool, range: Bool) {
        if range, let anchor = previewFile,
           let a = inputFiles.firstIndex(of: anchor), let b = inputFiles.firstIndex(of: file) {
            selection = Set(inputFiles[min(a, b)...max(a, b)])
            return
        }
        if toggle {
            if selection.contains(file) {
                if file != previewFile { selection.remove(file) }
                return
            }
            selection.insert(file)
        } else {
            selection = [file]
        }
        previewFile = file
    }

    func copyCurve() { copiedCurve = previewCurve }

    /// 把複製的曲線貼到 `files`，各自寫進自己的 XML（沿用曲線變更後的自動存檔）。
    func pasteCurve(to files: [URL]) {
        guard let copiedCurve else { return }
        for file in files { curves[file] = copiedCurve }
    }

    /// 換資料夾時先把還沒寫入的修改存檔，再讀新資料夾的 XML。
    private func loadCurves() {
        saveCurves()
        var loaded: [URL: BatchCurve] = [:]
        var unreadable: [String] = []
        for file in inputFiles {
            do {
                if let curve = try BatchCurve.load(forRaw: file) { loaded[file] = curve }
            } catch {
                unreadable.append(BatchCurve.url(forRaw: file).lastPathComponent)
            }
        }
        savedCurves = loaded
        curves = loaded
        if !unreadable.isEmpty { status = String(localized: "曲線檔無法讀取，視為沒有曲線：") + unreadable.joined(separator: "、") }
    }

    private func saveCurves() {
        var failed: [String] = []
        for (file, curve) in curves where savedCurves[file] != curve {
            do {
                try curve.save(forRaw: file)
                savedCurves[file] = curve
            } catch {
                failed.append(file.lastPathComponent)
            }
        }
        if !failed.isEmpty { status = String(localized: "曲線無法存檔（資料夾可能唯讀）：") + failed.joined(separator: "、") }
    }

    /// 換資料夾前先存舊照片的曝光，再讀各張自己的 sidecar。
    private func loadExposures() {
        saveExposures()
        var loaded: [URL: BatchExposureAdjustment] = [:]
        var unreadable: [String] = []
        for file in inputFiles {
            do {
                if let adjustment = try BatchExposureAdjustment.load(forPhoto: file) {
                    loaded[file] = adjustment
                }
            } catch {
                unreadable.append(BatchExposureAdjustment.sidecarURL(forPhoto: file).lastPathComponent)
            }
        }
        savedExposures = loaded
        exposures = loaded
        if !unreadable.isEmpty {
            status = String(localized: "曝光檔無法讀取，該照片使用中性曝光：") + unreadable.joined(separator: "、")
        }
    }

    /// Sidecar 寫入失敗會留在批次狀態列，原圖完全不會開啟寫入。
    @discardableResult
    private func saveExposures() -> [String] {
        let files = Set(savedExposures.keys).union(exposures.keys)
        var failed: [String] = []
        for file in files where savedExposures[file] != exposures[file] {
            let adjustment = exposures[file] ?? BatchExposureAdjustment()
            do {
                try adjustment.save(forPhoto: file)
                if adjustment.isNeutral { savedExposures.removeValue(forKey: file) }
                else { savedExposures[file] = adjustment }
            } catch {
                failed.append(file.lastPathComponent)
            }
        }
        if !failed.isEmpty {
            status = String(localized: "曝光檔無法存檔（資料夾可能唯讀）：") + failed.joined(separator: "、")
        }
        return failed
    }

    private func invalidateExposureMatchSnapshot() {
        exposureMatchRevision &+= 1
    }

    // MARK: 預覽

    /// 底片條上前後切換預覽照片。
    func stepPreview(_ offset: Int) {
        guard !inputFiles.isEmpty else { return }
        let current = previewFile.flatMap { inputFiles.firstIndex(of: $0) } ?? 0
        previewFile = inputFiles[min(max(current + offset, 0), inputFiles.count - 1)]
    }

    private func loadThumbnails() {
        thumbnailTask?.cancel()
        thumbnails = thumbnails.filter { inputFiles.contains($0.key) }
        let files = inputFiles.filter { thumbnails[$0] == nil }
        thumbnailTask = Task {
            for file in files {
                let image = await Task.detached(priority: .utility) { Self.thumbnail(for: file) }.value
                guard !Task.isCancelled else { return }
                if let image { thumbnails[file] = image }
            }
        }
    }

    nonisolated private static func thumbnail(for url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    func refreshPreview() {
        previewTask?.cancel()
        guard !isRunning, !isMatchingExposure, let file = previewFile, let base = makeSettings() else { return }
        let settings = self.settings(base, for: file)
        previewStatus = String(localized: "產生預覽中…")
        previewTask = Task {
            do {
                if previewExporter == nil { previewExporter = try makeExporter() }
                let exporter = previewExporter!
                let preview = try await Task.detached(priority: .userInitiated) {
                    try await exporter.preview(rawURL: file, settings: settings, maxDimension: 1200)
                }.value
                guard !Task.isCancelled else { return }
                previewImage = preview.image
                let result = preview.result
                var text = String(format: "EV %+.2f", result.appliedExposureEV)
                if result.appliedSkyEV != 0 { text += String(format: String(localized: "，天空 %+.2f"), result.appliedSkyEV) }
                if settings.isHDR { text += String(localized: "（預覽以 SDR 顯示）") }
                previewStatus = text
            } catch {
                guard !Task.isCancelled else { return }
                previewImage = nil
                previewStatus = String(localized: "預覽失敗：\(error)")
            }
        }
    }

    // MARK: 批次

    func matchSelectedExposure() {
        beginExposureMatch(for: selectedFiles)
    }

    func matchAllExposure() {
        beginExposureMatch(for: inputFiles)
    }

    private func beginExposureMatch(for requestedFiles: [URL]) {
        guard !isRunning, !isMatchingExposure else { return }
        saveCurves()
        let preMatchExposureSaveFailures = saveExposures()
        guard let referenceFile, inputFiles.contains(referenceFile) else {
            exposureMatchResult = String(localized: "請先把目前照片設為亮度參考。")
            return
        }
        let snapshotPreferences = prefs
        let snapshotCurves = curves
        let snapshotExposures = exposures
        let snapshotFiles = inputFiles
        let snapshotReference = referenceFile
        let requested = requestedFiles.filter { snapshotFiles.contains($0) && $0 != referenceFile }
        guard !requested.isEmpty else {
            exposureMatchResult = String(localized: "沒有可匹配的照片；請選取參考照以外的照片。")
            return
        }
        guard let baseSettings = makeSettings(using: snapshotPreferences) else { return }
        let referenceSettings = settings(baseSettings, for: referenceFile,
                                         preferences: snapshotPreferences,
                                         capturedCurves: snapshotCurves,
                                         capturedExposures: snapshotExposures)
        let targets = requested.map { file in
            BatchExposureMatchTarget(
                photo: file,
                settings: settings(baseSettings, for: file, preferences: snapshotPreferences,
                                   capturedCurves: snapshotCurves,
                                   capturedExposures: snapshotExposures))
        }
        let matcher: BatchExporter
        do { matcher = try makeExporter() }
        catch {
            exposureMatchResult = String(localized: "無法啟動亮度匹配：\(error)")
            return
        }

        previewTask?.cancel()
        exposureMatchRevision &+= 1
        let revision = exposureMatchRevision
        isMatchingExposure = true
        exposureMatchProgress = String(localized: "準備比對 0/\(targets.count) 張…")
        exposureMatchResult = ""
        exposureMatchTask = Task { [weak self] in
            guard let self else { return }
            let progress: @Sendable (Int, Int) -> Void = { [weak self] completed, total in
                Task { @MainActor [weak self] in
                    guard let self, self.exposureMatchRevision == revision else { return }
                    self.exposureMatchProgress = String(localized: "比對中：\(completed)/\(total) 張")
                }
            }
            let worker = Task.detached(priority: .userInitiated) {
                try await matcher.matchExposure(referenceURL: snapshotReference,
                                                referenceSettings: referenceSettings,
                                                targets: targets, maxDimension: 512,
                                                progress: progress)
            }
            do {
                let report = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { throw CancellationError() }
                guard self.exposureMatchRevision == revision,
                      self.prefs == snapshotPreferences,
                      self.curves == snapshotCurves,
                      self.exposures == snapshotExposures,
                      self.inputFiles == snapshotFiles,
                      self.referenceFile == snapshotReference else {
                    self.exposureMatchResult = String(localized: "設定或照片清單已變更，這次結果沒有套用。")
                    self.exposureMatchProgress = ""
                    self.isMatchingExposure = false
                    self.exposureMatchTask = nil
                    self.refreshPreview()
                    return
                }

                let successful = report.results.filter { !$0.isReference && $0.error == nil && $0.adjustment != nil }
                var previous: [URL: BatchExposureAdjustment] = [:]
                var next = self.exposures
                for item in successful {
                    previous[item.photo] = snapshotExposures[item.photo] ?? BatchExposureAdjustment()
                    if let adjustment = item.adjustment, !adjustment.isNeutral {
                        next[item.photo] = adjustment
                    } else {
                        next.removeValue(forKey: item.photo)
                    }
                }
                self.lastExposureMatchUndo = successful.isEmpty ? nil : previous
                self.canUndoExposureMatch = !successful.isEmpty
                self.exposures = next
                let saveFailures = Array(Set(preMatchExposureSaveFailures)
                    .union(self.saveExposures())).sorted()
                self.exposureMatchResult = Self.exposureMatchSummary(report, saveFailures: saveFailures)
                self.exposureMatchProgress = ""
                self.isMatchingExposure = false
                self.exposureMatchTask = nil
                self.refreshPreview()
            } catch is CancellationError {
                self.exposureMatchProgress = ""
                self.exposureMatchResult = String(localized: "已取消，沒有套用部分結果。")
                self.isMatchingExposure = false
                self.exposureMatchTask = nil
                self.refreshPreview()
            } catch {
                self.exposureMatchProgress = ""
                self.exposureMatchResult = String(localized: "亮度匹配失敗，沒有套用結果：\(error)")
                self.isMatchingExposure = false
                self.exposureMatchTask = nil
                self.refreshPreview()
            }
        }
    }

    private static func exposureMatchSummary(_ report: BatchExposureMatchReport,
                                             saveFailures: [String]) -> String {
        let matches = report.results.filter { !$0.isReference && $0.error == nil && $0.adjustment != nil }
        let limited = matches.filter { $0.search?.limitation == .highlights }
        let rangeLimited = matches.filter { $0.search?.limitation == .exposureRange }
        let failures = report.results.filter { !$0.isReference && $0.error != nil }
        var lines = [String(localized: "匹配完成：成功 \(matches.count) 張，受亮部限制 \(limited.count) 張，達曝光範圍仍未完全匹配 \(rangeLimited.count) 張，失敗 \(failures.count) 張。")]
        if report.referenceMeasurement.usedWholeImageFallback {
            lines.append(String(localized: "參考照找不到可靠主體權重，已用全圖亮度。"))
        }
        if report.usedSDRPreview { lines.append(String(localized: "HDR 照片以 SDR 預覽亮度匹配。")) }
        for item in matches {
            guard let search = item.search else { continue }
            let note: String
            switch search.limitation {
            case .none: note = ""
            case .highlights: note = String(localized: "（受亮部限制）")
            case .exposureRange: note = String(localized: "（已到曝光範圍，未完全匹配）")
            }
            let meter = search.measurement.usedWholeImageFallback ? String(localized: "（全圖測光）") : ""
            lines.append(String(format: "%@：EV %+.2f%@%@", item.photo.lastPathComponent,
                                search.totalEV, note, meter))
        }
        for item in failures {
            lines.append(String(localized: "\(item.photo.lastPathComponent)：失敗：\(item.error ?? "未知錯誤")"))
        }
        if !saveFailures.isEmpty { lines.append(String(localized: "曝光檔存檔失敗：") + saveFailures.joined(separator: "、")) }
        return lines.joined(separator: "\n")
    }

    func cancelExposureMatch() { exposureMatchTask?.cancel() }

    func start() {
        guard !isRunning, !isMatchingExposure else { return }
        let output = URL(fileURLWithPath: prefs.outputPath, isDirectory: true)
        saveCurves()
        let exposureSaveFailures = saveExposures()
        reloadInputFiles()
        guard !prefs.inputPath.isEmpty, !prefs.outputPath.isEmpty,
              (try? URL(fileURLWithPath: prefs.inputPath).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              (try? output.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            status = String(localized: "請選取有效的輸入與輸出資料夾。")
            return
        }
        let files = inputFiles
        guard !files.isEmpty else { status = String(localized: "資料夾內沒有支援的照片（RAW／JPEG／HEIC）。"); return }
        guard let settings = makeSettings() else { return }
        let fileSettings = files.map { self.settings(settings, for: $0) }
        let exporters: [BatchExporter]
        do {
            exporters = try (0..<effectiveConcurrency).map { _ in try makeExporter() }
        } catch {
            status = String(localized: "無法啟動渲染器：\(error)")
            return
        }

        previewTask?.cancel()
        completed = 0
        total = files.count
        rows = []
        isRunning = true
        status = String(localized: "準備處理 \(files.count) 張照片。")
        let skipExisting = prefs.skipExisting
        let smooth = prefs.smoothExposure && settings.automaticExposure
        runTask = Task {
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: String(localized: "RenderFilm 批次處理"))
            defer { ProcessInfo.processInfo.endActivity(activity) }

            // 決定每張的輸出位置；略過模式下已存在的直接記為略過。
            var pending: [(index: Int, destination: URL)] = []
            var reserved: Set<URL> = []
            var outcomes = [BatchReport.Outcome?](repeating: nil, count: files.count)
            let names = Self.outputNames(for: files)
            for (index, file) in files.enumerated() {
                let plain = output.appendingPathComponent(names[index])
                    .appendingPathExtension(settings.exporterFormat.fileExtension)
                if skipExisting && FileManager.default.fileExists(atPath: plain.path) {
                    outcomes[index] = .skipped
                } else {
                    let destination = skipExisting && !reserved.contains(plain) ? plain
                        : nextOutputURL(for: file, in: output, extension: settings.exporterFormat.fileExtension,
                                        reserved: reserved)
                    reserved.insert(destination)
                    pending.append((index, destination))
                }
            }
            completed = files.count - pending.count
            publishRows(files, outcomes)

            // EV 平滑：先分析每張的 EV，同組取中位數。
            var exposure = [Double?](repeating: nil, count: files.count)
            if smooth && !pending.isEmpty {
                let smoothIndices = pending.map(\.index)
                var analyzed = 0
                await forEachConcurrently(smoothIndices, exporters: exporters) { exporter, index in
                    try await exporter.analyzeExposure(rawURL: files[index], settings: fileSettings[index])
                } handle: { index, result in
                    analyzed += 1
                    self.status = String(localized: "分析曝光：\(analyzed)/\(smoothIndices.count)")
                    exposure[index] = try? result.get()
                }
                let groups = BatchExposureSmoothing.groups(files.map(BatchExposureSmoothing.Shot.read))
                exposure = BatchExposureSmoothing.smoothed(evs: exposure, groups: groups)
            }

            let started = Date()
            var finishedHere = 0
            let smoothedEV = exposure
            let destinations = Dictionary(uniqueKeysWithValues: pending.map { ($0.index, $0.destination) })
            await forEachConcurrently(pending.map(\.index), exporters: exporters) { exporter, index in
                try await exporter.process(rawURL: files[index], outputURL: destinations[index]!,
                                           settings: fileSettings[index], exposureEV: smoothedEV[index])
            } began: { index in
                self.inProgress.insert(files[index])
            } handle: { index, result in
                self.inProgress.remove(files[index])
                // 取消時中途停下的照片沒有輸出，不算失敗，維持未處理。
                if case .failure(let error) = result, error is CancellationError { return }
                switch result {
                case .success(let value): outcomes[index] = .exported(value)
                case .failure(let error): outcomes[index] = .failed(String(describing: error))
                }
                finishedHere += 1
                self.completed += 1
                self.publishRows(files, outcomes)
                let remaining = pending.count - finishedHere
                let eta = Date().timeIntervalSince(started) / Double(finishedHere) * Double(remaining)
                self.status = String(localized: "處理中：\(self.completed)/\(self.total)")
                    + (remaining > 0 ? String(localized: "，預估剩餘 \(Self.duration(eta))") : "")
                NSApp.dockTile.badgeLabel = "\(self.completed)/\(self.total)"
            }
            finish(cancelled: Task.isCancelled, output: output, settings: settings,
                   exposureSaveFailures: exposureSaveFailures)
        }
    }

    /// 最多 `exporters.count` 張同時進行；每個工作固定用自己的 exporter。`handle` 在主執行緒依完成順序呼叫。
    private func forEachConcurrently<T: Sendable>(
        _ indices: [Int], exporters: [BatchExporter],
        work: @escaping @Sendable (BatchExporter, Int) async throws -> T,
        began: (Int) -> Void = { _ in },
        handle: (Int, Result<T, Error>) -> Void
    ) async {
        await withTaskGroup(of: (Int, Int, Result<T, Error>).self) { group in
            var queue = indices[...]
            func launch(_ slot: Int) {
                guard !Task.isCancelled, let index = queue.popFirst() else { return }
                let exporter = exporters[slot]
                began(index)
                group.addTask {
                    do { return (slot, index, .success(try await work(exporter, index))) }
                    catch { return (slot, index, .failure(error)) }
                }
            }
            for slot in exporters.indices { launch(slot) }
            for await (slot, index, result) in group {
                handle(index, result)
                launch(slot)
            }
        }
    }

    private func publishRows(_ files: [URL], _ outcomes: [BatchReport.Outcome?]) {
        rows = zip(files, outcomes).compactMap { file, outcome in
            outcome.map { BatchReport.Row(file: file.lastPathComponent, outcome: $0) }
        }
    }

    private func finish(cancelled: Bool, output: URL, settings: BatchExportSettings,
                        exposureSaveFailures: [String] = []) {
        var exported = 0, skipped = 0, failed = 0, neural = 0, superResolved = 0, straightened = 0
        for row in rows {
            switch row.outcome {
            case .exported(let result):
                exported += 1
                if result.neuralNoiseReduction { neural += 1 }
                if result.superResolved { superResolved += 1 }
                if result.straightenDegrees != 0 { straightened += 1 }
            case .skipped: skipped += 1
            case .failed: failed += 1
            }
        }
        var text = cancelled ? String(localized: "已取消：") : String(localized: "已完成：")
        text += String(localized: "輸出 \(exported)，略過 \(skipped)，失敗 \(failed)（共 \(total)）。")
        if settings.superResolution { text += String(localized: "ML 超解析度 \(superResolved) 張。") }
        if settings.automaticStraighten { text += String(localized: "自動水平 \(straightened) 張。") }
        if settings.noiseReduction != nil {
            text += String(localized: "RAW 降噪：RAW 9 ML \(neural) 張，其餘 RAW 使用一般降噪；JPEG／HEIC 不套用。")
        }
        if !exposureSaveFailures.isEmpty {
            text += String(localized: "曝光 sidecar 存檔失敗：") + exposureSaveFailures.joined(separator: "、") + "。"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let report = output.appendingPathComponent("renderfilm-batch-\(formatter.string(from: Date())).csv")
        do {
            try BatchReport.csv(rows).write(to: report, atomically: true, encoding: .utf8)
            text += String(localized: "報告：\(report.lastPathComponent)")
        } catch {
            text += String(localized: "報告寫入失敗：\(error)")
        }
        status = text
        isRunning = false
        inProgress = []
        runTask = nil
        refreshPreview()
        NSApp.dockTile.badgeLabel = nil
        NSApp.requestUserAttention(.informationalRequest)
        notify(text)
    }

    /// 通知需要 App bundle；用 `swift run` 直接執行時沒有 bundle，只略過通知。
    private func notify(_ text: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "RenderFilm 批次處理")
            content.body = text
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600 ? String(localized: "\(total / 3600) 小時 \(total % 3600 / 60) 分")
            : total >= 60 ? String(localized: "\(total / 60) 分 \(total % 60) 秒") : String(localized: "\(total) 秒")
    }

    func cancel() { runTask?.cancel() }

    /// 只依輸入清單決定每張的輸出檔名，每次重跑結果相同，略過模式才判斷得出各張是否已輸出。
    /// 同名不同副檔名的照片依序得到 A、A-2…，並避開來源資料夾內已存在的同名檔案。
    private static func outputNames(for files: [URL]) -> [String] {
        let stems = files.map { $0.deletingPathExtension().lastPathComponent }
        let taken = Set(stems)
        var used: Set<String> = []
        return stems.map { stem in
            var name = stem
            var number = 2
            while used.contains(name) || (name != stem && taken.contains(name)) {
                name = "\(stem)-\(number)"
                number += 1
            }
            used.insert(name)
            return name
        }
    }

    private func nextOutputURL(for input: URL, in folder: URL, extension ext: String,
                               reserved: Set<URL>) -> URL {
        let stem = input.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent(stem).appendingPathExtension(ext)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(candidate) {
            candidate = folder.appendingPathComponent("\(stem)-\(number)").appendingPathExtension(ext)
            number += 1
        }
        return candidate
    }
}
