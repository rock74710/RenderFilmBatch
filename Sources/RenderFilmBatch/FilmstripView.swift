import SwiftUI
import RFCore

/// 底部底片條：點選或左右鍵切換預覽照片，並標示每張的批次輸出狀態。
struct FilmstripView: View {
    @ObservedObject var model: BatchModel
    @FocusState private var focused: Bool

    var body: some View {
        let outcomes = Dictionary(model.rows.map { ($0.file, $0.outcome) }, uniquingKeysWith: { _, last in last })
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(model.inputFiles.enumerated()), id: \.element) { index, file in
                        FilmFrame(number: index + 1, name: file.lastPathComponent,
                                  thumbnail: model.thumbnails[file],
                                  selected: file == model.previewFile,
                                  marked: model.selection.contains(file),
                                  state: state(for: file, outcome: outcomes[file.lastPathComponent]))
                            .id(file)
                            .onTapGesture {
                                let modifiers = NSEvent.modifierFlags
                                model.select(file, toggle: modifiers.contains(.command),
                                             range: modifiers.contains(.shift))
                                focused = true
                            }
                    }
                }
                .padding(.horizontal, 12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { model.stepPreview(-1); return .handled }
            .onKeyPress(.rightArrow) { model.stepPreview(1); return .handled }
            .onChange(of: model.previewFile) { _, file in
                guard let file else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(file, anchor: .center) }
            }
        }
    }

    private func state(for file: URL, outcome: BatchReport.Outcome?) -> FilmFrame.State {
        if model.inProgress.contains(file) { return .running }
        switch outcome {
        case .exported: return .exported
        case .skipped: return .skipped
        case .failed: return .failed
        case nil: return .pending
        }
    }
}

private struct FilmFrame: View {
    enum State { case pending, running, exported, skipped, failed }

    let number: Int
    let name: String
    let thumbnail: CGImage?
    let selected: Bool
    /// 多選中（不是預覽的那張）：細框。
    let marked: Bool
    let state: State

    private static let edge = Color(red: 1, green: 0.62, blue: 0.04)

    var body: some View {
        ZStack {
            Rectangle().fill(selected ? Color(red: 0.16, green: 0.12, blue: 0.08) : Color(red: 0.09, green: 0.07, blue: 0.05))
            sprockets
            ZStack(alignment: .bottomLeading) {
                // 縮圖放在 overlay 裡裁切，直幅照片才不會撐大格子。
                Rectangle().fill(.white.opacity(0.06))
                    .overlay {
                        if let thumbnail {
                            Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                        }
                    }
                    .clipped()
                Text("\(number)  \(name)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Self.edge.opacity(0.85))
                    .shadow(color: .black, radius: 1)
                    .padding(4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay(alignment: .topTrailing) { statusDot.padding(4) }
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Self.edge, lineWidth: selected ? 2 : marked ? 1 : 0))
            .padding(.horizontal, 6)
            .padding(.vertical, 20)
        }
        .frame(width: 140)
        .overlay(alignment: .trailing) { Rectangle().fill(.black).frame(width: 1) }
        .contentShape(Rectangle())
    }

    /// 上下兩排齒孔。
    private var sprockets: some View {
        Canvas { context, size in
            var x = 8.0
            while x + 8 <= size.width {
                for y in [6.0, size.height - 16] {
                    context.fill(Path(roundedRect: CGRect(x: x, y: y, width: 8, height: 10), cornerRadius: 2),
                                 with: .color(Color(white: 0.82).opacity(0.75)))
                }
                x += 23
            }
        }
    }

    @ViewBuilder private var statusDot: some View {
        let color: Color? = switch state {
        case .pending: nil
        case .running: Self.edge
        case .exported: .green
        case .skipped: .gray
        case .failed: .red
        }
        if let color {
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .symbolEffect(.pulse, isActive: state == .running)
                .opacity(state == .running ? 0.9 : 1)
        }
    }
}
