import SwiftUI

struct GraphLayer {
    var values: [Double]
    var color: Color
}

private func smoothAdd(_ pts: [CGPoint], to p: inout Path, connect: Bool) {
    guard let first = pts.first else { return }
    if connect { p.addLine(to: first) } else { p.move(to: first) }
    guard pts.count > 1 else { return }
    for i in 1..<pts.count {
        let prev = pts[i - 1], cur = pts[i]
        let mid = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
        if i == 1 { p.addLine(to: mid) } else { p.addQuadCurve(to: mid, control: prev) }
    }
    p.addLine(to: pts[pts.count - 1])
}

private func drawGrid(_ ctx: GraphicsContext, _ size: CGSize, lines: Int) {
    guard lines > 0 else { return }
    for i in 1...lines {
        let y = size.height * CGFloat(i) / CGFloat(lines + 1)
        var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
        ctx.stroke(p, with: .color(.primary.opacity(0.07)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
    }
}

/// Smooth, optionally stacked, gradient-filled area graph.
struct AreaGraph: View {
    var layers: [GraphLayer]
    var maxValue: Double? = nil
    var stacked = false
    var capacity = 120
    var gridLines = 3
    var minScale = 0.0

    var body: some View {
        Canvas { ctx, size in
            drawGrid(ctx, size, lines: gridLines)
            let n = layers.map(\.values.count).max() ?? 0
            guard n > 0, size.width > 0 else {
                var p = Path(); p.move(to: CGPoint(x: 0, y: size.height - 0.5)); p.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                ctx.stroke(p, with: .color(.primary.opacity(0.15)), lineWidth: 1)
                return
            }
            // cumulative values
            var cum: [[Double]] = []
            for (li, l) in layers.enumerated() {
                var arr = l.values
                if stacked, li > 0 {
                    let below = cum[li - 1]
                    for i in 0..<arr.count { arr[i] += i < below.count ? below[i] : 0 }
                }
                cum.append(arr)
            }
            let topMax = max(minScale, cum.compactMap { $0.max() }.max() ?? 0)
            let ymax = maxValue ?? Fmt.niceMax(max(topMax, 0.0001))
            let step = size.width / CGFloat(max(1, capacity - 1))
            func pts(_ arr: [Double]) -> [CGPoint] {
                let off = capacity - arr.count
                return arr.enumerated().map { i, v in
                    CGPoint(x: CGFloat(max(0, off) + i) * step,
                            y: size.height - CGFloat(min(1, max(0, v / ymax))) * (size.height - 2) - 1)
                }
            }
            for (li, l) in layers.enumerated() {
                let top = pts(cum[li])
                let bottom: [CGPoint] = (stacked && li > 0) ? pts(cum[li - 1]) :
                    top.map { CGPoint(x: $0.x, y: size.height) }
                var fill = Path()
                smoothAdd(top, to: &fill, connect: false)
                smoothAdd(bottom.reversed(), to: &fill, connect: true)
                fill.closeSubpath()
                ctx.fill(fill, with: .linearGradient(
                    Gradient(colors: [l.color.opacity(stacked ? 0.75 : 0.55), l.color.opacity(stacked ? 0.45 : 0.06)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                var line = Path(); smoothAdd(top, to: &line, connect: false)
                ctx.stroke(line, with: .color(l.color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// Download above the axis, upload below.
struct MirroredGraph: View {
    var down: [Double]
    var up: [Double]
    var scale: Double
    var downColor = Theme.down
    var upColor = Theme.up
    var capacity = 120

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            let step = size.width / CGFloat(max(1, capacity - 1))
            for (arr, color, dir) in [(down, downColor, -1.0), (up, upColor, 1.0)] {
                guard !arr.isEmpty else { continue }
                let off = capacity - arr.count
                let pts = arr.enumerated().map { i, v in
                    CGPoint(x: CGFloat(max(0, off) + i) * step,
                            y: mid + CGFloat(dir) * CGFloat(min(1, max(0, v / scale))) * (mid - 2))
                }
                var fill = Path()
                smoothAdd(pts, to: &fill, connect: false)
                fill.addLine(to: CGPoint(x: pts.last!.x, y: mid)); fill.addLine(to: CGPoint(x: pts.first!.x, y: mid)); fill.closeSubpath()
                let g = Gradient(colors: dir < 0 ? [color.opacity(0.08), color.opacity(0.65)] : [color.opacity(0.65), color.opacity(0.08)])
                ctx.fill(fill, with: .linearGradient(g, startPoint: CGPoint(x: 0, y: dir < 0 ? 0 : mid),
                                                    endPoint: CGPoint(x: 0, y: dir < 0 ? mid : size.height)))
                var line = Path(); smoothAdd(pts, to: &line, connect: false)
                ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
            var axis = Path(); axis.move(to: CGPoint(x: 0, y: mid)); axis.addLine(to: CGPoint(x: size.width, y: mid))
            ctx.stroke(axis, with: .color(.primary.opacity(0.18)), lineWidth: 0.75)
        }
    }
}

struct Sparkline: View {
    var values: [Double]
    var color: Color
    var maxValue: Double? = nil
    var capacity = 120
    /// Smallest vertical range shown, so sensor noise (±0.5°) doesn't look like a cliff.
    var minSpan: Double = 6
    var body: some View {
        // Auto-scale around the data, centred, with a floor on the visible range.
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let span = max(hi - lo, minSpan)
        let base = (lo + hi) / 2 - span / 2
        let shifted = values.map { $0 - base + span * 0.15 }
        AreaGraph(layers: [GraphLayer(values: shifted, color: color)], maxValue: maxValue ?? span * 1.25, capacity: capacity, gridLines: 0)
    }
}

struct BarMeter: View {
    var value: Double          // 0...1
    var color: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule().fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, g.size.width * CGFloat(min(1, max(0, value)))))
                    .opacity(value <= 0.001 ? 0 : 1)
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.5), value: value)
    }
}

struct Segment: Identifiable {
    var id: String
    var value: Double
    var color: Color
}

struct StackedBar: View {
    var segments: [Segment]
    var height: CGFloat = 10
    var body: some View {
        GeometryReader { g in
            let total = max(segments.map(\.value).reduce(0, +), 0.000001)
            HStack(spacing: 1.5) {
                ForEach(segments) { s in
                    if s.value > 0 {
                        RoundedRectangle(cornerRadius: 2.5).fill(s.color)
                            .frame(width: max(2, (g.size.width - 1.5 * CGFloat(segments.count)) * CGFloat(s.value / total)))
                    }
                }
                Spacer(minLength: 0)
            }
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.5), value: segments.map(\.value))
    }
}

struct RingGauge<Center: View>: View {
    var value: Double
    var color: Color
    var lineWidth: CGFloat = 9
    @ViewBuilder var center: Center
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.09), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.004, min(1, value)))
                .stroke(AngularGradient(colors: [color.opacity(0.55), color], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(0.05, value))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center
        }
        .padding(lineWidth / 2)
        .animation(.smooth(duration: 0.6), value: value)
    }
}
