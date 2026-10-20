import Foundation

/// 內容感知填補：洞內每個小區塊各自到整個搜尋範圍找最像的區塊（PatchMatch 近鄰搜尋），
/// 再由所有覆蓋同一像素的區塊投票決定顏色，由粗到細多層反覆。
/// 參考 Barnes et al. “PatchMatch”（SIGGRAPH 2009）與 Wexler et al. “Space-Time Completion of
/// Video”（TPAMI 2007）的公開方法，獨立實作。像素為 RGBA 浮點、第 0 列在上緣；只改洞內 RGB。
enum RetouchPatchMatch {
    static let patchRadius = 3

    /// 回傳填好的像素；沒有任何可用來源區塊時回傳 nil，由呼叫端退回其他填法。
    static func inpaint(pixels: [Float], hole: [Bool], width: Int, height: Int) throws -> [Float]? {
        guard hole.contains(true) else { return pixels }
        // 以壓縮後的數值比較與投票，讓 HDR 高光不壓過一般亮度；最後再還原。
        var levels = [Level(width: width, height: height,
                            color: compress(pixels, count: width * height), hole: hole)]
        while let coarser = levels.last!.downsampled(), coarser.holeSpan >= 2 * patchRadius + 1 {
            levels.append(coarser)
        }

        var field: Field?
        for levelIndex in stride(from: levels.count - 1, through: 0, by: -1) {
            try checkCancellation()
            let level = levels[levelIndex]
            guard let sources = level.validSources(radius: patchRadius) else { return nil }
            var current = level
            if var previous = field {
                previous = previous.upsampled(to: current, sources: sources)
                current.vote(field: previous)
                field = previous
            } else {
                current.fillHoleFromBoundary()
                field = Field(level: current, sources: sources)
            }
            let iterations = levelIndex == levels.count - 1 ? 8 : (levelIndex == 0 ? 3 : 4)
            for iteration in 0..<iterations {
                try checkCancellation()
                field!.search(level: current, sources: sources, passes: 2, seed: UInt64(levelIndex * 97 + iteration))
                current.vote(field: field!)
            }
            levels[levelIndex] = current
        }

        // 區塊取樣容易整體偏亮或偏暗；保留它的細節，低頻明暗改用由周圍邊界平滑延伸的結果。
        var filled = levels[0]
        let smooth = smoothFill(levels)
        let lowFilled = boxBlur(filled.color, hole: filled.hole, width: width, height: height, radius: 12)
        let lowSmooth = boxBlur(smooth, hole: filled.hole, width: width, height: height, radius: 12)
        for index in 0..<(width * height) where hole[index] {
            for channel in 0..<3 {
                let i = index * 3 + channel
                filled.color[i] = min(0.999, max(-0.999, filled.color[i] + lowSmooth[i] - lowFilled[i]))
            }
        }

        var result = pixels
        for index in 0..<(width * height) where hole[index] {
            for channel in 0..<3 {
                let value = filled.color[index * 3 + channel]
                result[index * 4 + channel] = value / max(1e-6, 1 - abs(value))
            }
        }
        return result
    }

    /// 洞內的平滑填色（接近每點等於鄰居平均）：最粗層由外往內填，之後每層放大後再鬆弛幾輪。
    private static func smoothFill(_ levels: [Level]) -> [Float] {
        var coarse = levels.last!
        coarse.fillHoleFromBoundary()
        var color = coarse.color
        relax(&color, level: coarse, iterations: 40)
        for index in stride(from: levels.count - 2, through: 0, by: -1) {
            let level = levels[index], coarser = levels[index + 1]
            var next = level.color
            for pixel in 0..<(level.width * level.height) where level.hole[pixel] {
                let x = min(coarser.width - 1, (pixel % level.width) / 2)
                let y = min(coarser.height - 1, (pixel / level.width) / 2)
                for channel in 0..<3 { next[pixel * 3 + channel] = color[(y * coarser.width + x) * 3 + channel] }
            }
            relax(&next, level: level, iterations: index == 0 ? 30 : 20)
            color = next
        }
        return color
    }

    private static func relax(_ color: inout [Float], level: Level, iterations: Int) {
        let w = level.width, h = level.height
        let cells = (0..<(w * h)).filter { level.hole[$0] }
        for _ in 0..<iterations {
            for index in cells {
                let x = index % w, y = index / w
                var sum = SIMD3<Float>.zero, count: Float = 0
                for n in [x > 0 ? index - 1 : -1, x + 1 < w ? index + 1 : -1,
                          y > 0 ? index - w : -1, y + 1 < h ? index + w : -1] where n >= 0 {
                    sum += SIMD3(color[n * 3], color[n * 3 + 1], color[n * 3 + 2]); count += 1
                }
                let value = sum / count
                color[index * 3] = value.x; color[index * 3 + 1] = value.y; color[index * 3 + 2] = value.z
            }
        }
    }

    /// 只在洞附近的方框模糊（水平再垂直），用來取低頻明暗。
    private static func boxBlur(_ color: [Float], hole: [Bool], width: Int, height: Int, radius: Int) -> [Float] {
        var minX = width, maxX = -1, minY = height, maxY = -1
        for index in 0..<(width * height) where hole[index] {
            minX = min(minX, index % width); maxX = max(maxX, index % width)
            minY = min(minY, index / width); maxY = max(maxY, index / width)
        }
        guard maxX >= minX else { return color }
        let x0 = max(0, minX - 2 * radius), x1 = min(width - 1, maxX + 2 * radius)
        let y0 = max(0, minY - 2 * radius), y1 = min(height - 1, maxY + 2 * radius)
        var horizontal = color, result = color
        for y in y0...y1 {
            for x in x0...x1 {
                var sum = SIMD3<Float>.zero, count: Float = 0
                for nx in max(x0, x - radius)...min(x1, x + radius) {
                    let n = (y * width + nx) * 3
                    sum += SIMD3(color[n], color[n + 1], color[n + 2]); count += 1
                }
                let i = (y * width + x) * 3
                horizontal[i] = sum.x / count; horizontal[i + 1] = sum.y / count; horizontal[i + 2] = sum.z / count
            }
        }
        for y in y0...y1 {
            for x in x0...x1 {
                var sum = SIMD3<Float>.zero, count: Float = 0
                for ny in max(y0, y - radius)...min(y1, y + radius) {
                    let n = (ny * width + x) * 3
                    sum += SIMD3(horizontal[n], horizontal[n + 1], horizontal[n + 2]); count += 1
                }
                let i = (y * width + x) * 3
                result[i] = sum.x / count; result[i + 1] = sum.y / count; result[i + 2] = sum.z / count
            }
        }
        return result
    }

    private static func compress(_ pixels: [Float], count: Int) -> [Float] {
        var color = [Float](repeating: 0, count: count * 3)
        for index in 0..<count {
            for channel in 0..<3 {
                let value = pixels[index * 4 + channel]
                color[index * 3 + channel] = value / (1 + abs(value))
            }
        }
        return color
    }

    private static func checkCancellation() throws {
        if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) { throw CancellationError() }
    }

    private struct Level {
        let width: Int, height: Int
        var color: [Float]
        let hole: [Bool]

        var holeSpan: Int {
            var minX = width, maxX = -1, minY = height, maxY = -1
            for index in 0..<(width * height) where hole[index] {
                let x = index % width, y = index / width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
            return maxX < minX ? 0 : max(maxX - minX, maxY - minY) + 1
        }

        /// 長寬各減半；只要有一個子像素在洞內就算洞，避免洞的顏色滲進已知像素。
        func downsampled() -> Level? {
            let w = width / 2, h = height / 2
            guard w >= 4 * RetouchPatchMatch.patchRadius, h >= 4 * RetouchPatchMatch.patchRadius else { return nil }
            var color = [Float](repeating: 0, count: w * h * 3)
            var hole = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    var sum = SIMD3<Float>.zero
                    var isHole = false
                    for (cx, cy) in [(2 * x, 2 * y), (2 * x + 1, 2 * y), (2 * x, 2 * y + 1), (2 * x + 1, 2 * y + 1)] {
                        let child = cy * width + cx
                        isHole = isHole || self.hole[child]
                        sum += SIMD3(self.color[child * 3], self.color[child * 3 + 1], self.color[child * 3 + 2])
                    }
                    let index = y * w + x
                    hole[index] = isHole
                    color[index * 3] = sum.x / 4; color[index * 3 + 1] = sum.y / 4; color[index * 3 + 2] = sum.z / 4
                }
            }
            return Level(width: w, height: h, color: color, hole: hole)
        }

        /// 區塊完全落在影像內且不碰到洞的中心點，才能當來源。
        func validSources(radius: Int) -> Sources? {
            // 洞的累積和表，用來快速判斷一個區塊內有沒有洞。
            var table = [Int32](repeating: 0, count: (width + 1) * (height + 1))
            for y in 0..<height {
                var row: Int32 = 0
                for x in 0..<width {
                    row += hole[y * width + x] ? 1 : 0
                    table[(y + 1) * (width + 1) + x + 1] = table[y * (width + 1) + x + 1] + row
                }
            }
            func holeCount(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int32 {
                table[(y1 + 1) * (width + 1) + x1 + 1] - table[y0 * (width + 1) + x1 + 1]
                    - table[(y1 + 1) * (width + 1) + x0] + table[y0 * (width + 1) + x0]
            }
            var valid = [Bool](repeating: false, count: width * height)
            var list: [Int32] = []
            var targets: [Int32] = []
            guard width > 2 * radius, height > 2 * radius else { return nil }
            for y in radius..<(height - radius) {
                for x in radius..<(width - radius) {
                    let count = holeCount(x - radius, y - radius, x + radius, y + radius)
                    let index = y * width + x
                    if count == 0 {
                        valid[index] = true
                        list.append(Int32(index))
                    } else {
                        targets.append(Int32(index))
                    }
                }
            }
            guard !list.isEmpty, !targets.isEmpty else { return nil }
            return Sources(valid: valid, list: list, targets: targets)
        }

        /// 最粗層的起始猜值：由洞外一圈一圈往內取已知鄰居平均。
        mutating func fillHoleFromBoundary() {
            var known = hole.map { !$0 }
            var pending = (0..<(width * height)).filter { hole[$0] }
            while !pending.isEmpty {
                var next: [Int] = [], updates: [(Int, SIMD3<Float>)] = []
                for index in pending {
                    let x = index % width, y = index / width
                    var sum = SIMD3<Float>.zero, count: Float = 0
                    for ny in max(0, y - 1)...min(height - 1, y + 1) {
                        for nx in max(0, x - 1)...min(width - 1, x + 1) where known[ny * width + nx] {
                            let n = ny * width + nx
                            sum += SIMD3(color[n * 3], color[n * 3 + 1], color[n * 3 + 2]); count += 1
                        }
                    }
                    if count > 0 { updates.append((index, sum / count)) } else { next.append(index) }
                }
                if updates.isEmpty { break }
                for (index, value) in updates {
                    color[index * 3] = value.x; color[index * 3 + 1] = value.y; color[index * 3 + 2] = value.z
                    known[index] = true
                }
                pending = next
            }
        }

        /// 每個洞內像素 = 覆蓋它的所有目標區塊對應來源像素的加權平均；越像的區塊權重越大。
        mutating func vote(field: Field) {
            let radius = RetouchPatchMatch.patchRadius
            var sums = [Float](repeating: 0, count: width * height * 3)
            var weights = [Float](repeating: 0, count: width * height)
            var sortedDistances = field.distance.filter(\.isFinite).sorted()
            if sortedDistances.isEmpty { sortedDistances = [1] }
            let scale = max(1e-6, sortedDistances[sortedDistances.count * 3 / 4])
            for (slot, rawTarget) in field.targets.enumerated() {
                let target = Int(rawTarget), source = Int(field.source[slot])
                let weight = exp(-field.distance[slot] / scale)
                let tx = target % width, ty = target / width
                let sx = source % width, sy = source / width
                for oy in -radius...radius {
                    for ox in -radius...radius {
                        let pixel = (ty + oy) * width + tx + ox
                        guard hole[pixel] else { continue }
                        let from = ((sy + oy) * width + sx + ox) * 3
                        sums[pixel * 3] += weight * color[from]
                        sums[pixel * 3 + 1] += weight * color[from + 1]
                        sums[pixel * 3 + 2] += weight * color[from + 2]
                        weights[pixel] += weight
                    }
                }
            }
            for index in 0..<(width * height) where hole[index] && weights[index] > 0 {
                for channel in 0..<3 { color[index * 3 + channel] = sums[index * 3 + channel] / weights[index] }
            }
        }
    }

    private struct Sources {
        let valid: [Bool]
        let list: [Int32]
        /// 區塊內含有洞像素的中心點，也就是需要找來源的目標。
        let targets: [Int32]
    }

    private struct Field {
        let width: Int
        let targets: [Int32]
        var source: [Int32]
        var distance: [Float]

        init(level: Level, sources: Sources) {
            width = level.width
            targets = sources.targets
            var generator = SplitMix(seed: 0x5eed)
            source = targets.map { _ in sources.list[Int(generator.next() % UInt64(sources.list.count))] }
            distance = [Float](repeating: .infinity, count: targets.count)
            for slot in targets.indices {
                distance[slot] = Field.patchDistance(level, Int(targets[slot]), Int(source[slot]), limit: .infinity)
            }
        }

        /// 把上一層的對應位移放大兩倍，作為這一層的起點；不合法時改用隨機來源。
        func upsampled(to level: Level, sources: Sources) -> Field {
            var result = Field(width: level.width, targets: sources.targets,
                               source: [Int32](repeating: 0, count: sources.targets.count),
                               distance: [Float](repeating: .infinity, count: sources.targets.count))
            var coarseSlot = [Int32: Int]()
            for (slot, target) in targets.enumerated() { coarseSlot[target] = slot }
            var generator = SplitMix(seed: 0xfeed)
            let coarseWidth = width
            for (slot, rawTarget) in result.targets.enumerated() {
                let target = Int(rawTarget)
                let x = target % level.width, y = target / level.width
                var candidate = -1
                let coarseTarget = Int32((y / 2) * coarseWidth + x / 2)
                if let previous = coarseSlot[coarseTarget] {
                    let coarseSource = Int(source[previous])
                    let sx = 2 * (coarseSource % coarseWidth) + x % 2
                    let sy = 2 * (coarseSource / coarseWidth) + y % 2
                    if sx < level.width, sy < level.height, sources.valid[sy * level.width + sx] {
                        candidate = sy * level.width + sx
                    }
                }
                if candidate < 0 { candidate = Int(sources.list[Int(generator.next() % UInt64(sources.list.count))]) }
                result.source[slot] = Int32(candidate)
                result.distance[slot] = Field.patchDistance(level, target, candidate, limit: .infinity)
            }
            return result
        }

        private init(width: Int, targets: [Int32], source: [Int32], distance: [Float]) {
            self.width = width; self.targets = targets; self.source = source; self.distance = distance
        }

        /// PatchMatch：交替方向掃描，先沿用左/上（或右/下）鄰居的位移，再在逐步縮小的範圍內隨機找。
        mutating func search(level: Level, sources: Sources, passes: Int, seed: UInt64) {
            for slot in targets.indices {
                distance[slot] = Field.patchDistance(level, Int(targets[slot]), Int(source[slot]), limit: .infinity)
            }
            var slotOf = [Int32](repeating: -1, count: level.width * level.height)
            for (slot, target) in targets.enumerated() { slotOf[Int(target)] = Int32(slot) }
            var generator = SplitMix(seed: seed &+ 1)
            let w = level.width, h = level.height
            for pass in 0..<passes {
                let forward = pass.isMultiple(of: 2)
                let step = forward ? 1 : -1
                for order in targets.indices {
                    let slot = forward ? order : targets.count - 1 - order
                    let target = Int(targets[slot])
                    let tx = target % w, ty = target / w
                    func consider(_ candidate: Int) {
                        guard candidate >= 0, candidate < w * h, sources.valid[candidate],
                              candidate != Int(source[slot]) else { return }
                        let value = Field.patchDistance(level, target, candidate, limit: distance[slot])
                        if value < distance[slot] { distance[slot] = value; source[slot] = Int32(candidate) }
                    }
                    for (nx, ny) in [(tx - step, ty), (tx, ty - step)] where nx >= 0 && nx < w && ny >= 0 && ny < h {
                        let neighborSlot = Int(slotOf[ny * w + nx])
                        guard neighborSlot >= 0 else { continue }
                        let neighborSource = Int(source[neighborSlot])
                        let sx = neighborSource % w + (tx - nx), sy = neighborSource / w + (ty - ny)
                        if sx >= 0, sx < w, sy >= 0, sy < h { consider(sy * w + sx) }
                    }
                    var radius = max(w, h)
                    while radius >= 1 {
                        let current = Int(source[slot])
                        let cx = current % w, cy = current / w
                        let sx = cx + Int(generator.next() % UInt64(2 * radius + 1)) - radius
                        let sy = cy + Int(generator.next() % UInt64(2 * radius + 1)) - radius
                        if sx >= 0, sx < w, sy >= 0, sy < h { consider(sy * w + sx) }
                        radius /= 2
                    }
                }
            }
        }

        static func patchDistance(_ level: Level, _ target: Int, _ source: Int, limit: Float) -> Float {
            let radius = RetouchPatchMatch.patchRadius, w = level.width
            let tx = target % w, ty = target / w, sx = source % w, sy = source / w
            var total: Float = 0
            return level.color.withUnsafeBufferPointer { color in
                for oy in -radius...radius {
                    let tRow = ((ty + oy) * w + tx) * 3, sRow = ((sy + oy) * w + sx) * 3
                    for ox in -radius...radius {
                        let a = tRow + ox * 3, b = sRow + ox * 3
                        let d0 = color[a] - color[b], d1 = color[a + 1] - color[b + 1], d2 = color[a + 2] - color[b + 2]
                        total += d0 * d0 + d1 * d1 + d2 * d2
                    }
                    if total >= limit { return total }
                }
                return total
            }
        }
    }

    /// 固定種子的亂數，讓同一張圖每次修補結果一致。
    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}
