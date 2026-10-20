import SwiftUI
import RFCore

/// Five-point RGB curve; RFCore supplies the exact interpolation used for rendering.
struct BatchCurveView: View {
    @Binding var points: [Double]
    /// true 時拖曳吸附到十等分格線。
    var snap = false
    var color: Color = .accentColor
    /// RGB 模式下其他通道的曲線，淡色畫在底下作參考。
    var references: [(points: [Double], color: Color)] = []
    @State private var selectedNode: Int?

    private var activePoints: [Double] { CurveEditing.points(points) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)
                ZStack {
                    Rectangle().fill(.black.opacity(0.08))
                    Path { path in
                        let divisions = CurveEditing.gridDivisions
                        for step in 1..<divisions {
                            let offset = Double(step) / Double(divisions) * side
                            path.move(to: CGPoint(x: offset, y: 0))
                            path.addLine(to: CGPoint(x: offset, y: side))
                            path.move(to: CGPoint(x: 0, y: offset))
                            path.addLine(to: CGPoint(x: side, y: offset))
                        }
                    }
                    .stroke(.secondary.opacity(0.2), lineWidth: 0.5)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: side))
                        path.addLine(to: CGPoint(x: side, y: 0))
                    }
                    .stroke(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    ForEach(references.indices, id: \.self) { index in
                        curvePath(references[index].points, side: side)
                            .stroke(references[index].color.opacity(0.35), lineWidth: 1.5)
                    }
                    curvePath(points, side: side).stroke(color, lineWidth: 2)
                    ForEach(0..<activePoints.count, id: \.self) { index in
                        Circle()
                            .fill(color)
                            .frame(width: 10, height: 10)
                            .position(x: Double(index) / Double(activePoints.count - 1) * side,
                                      y: (1 - activePoints[index]) * side)
                    }
                }
                .frame(width: side, height: side)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let node = selectedNode ?? CurveEditing.nearestNode(
                        at: Double(value.startLocation.x / side)
                    )
                    selectedNode = node
                    points = CurveEditing.moved(points, node: node,
                                                 to: 1 - Double(value.location.y / side), snap: snap)
                }.onEnded { _ in selectedNode = nil })
            }
        }
    }

    private func curvePath(_ points: [Double], side: Double) -> Path {
        Path { path in
            let samples = CurveEditing.sampled(points, count: 128)
            for (index, value) in samples.enumerated() {
                let point = CGPoint(x: Double(index) / Double(samples.count - 1) * side,
                                    y: (1 - value) * side)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}
