import SwiftUI

// iStat-Menus-style building blocks: cards, blue titles, bar histories, ring gauges.

/// Rounded translucent card with a hairline border.
struct Card<Content: View>: View {
    var spacing: CGFloat = 6
    var vPad: CGFloat = 10
    var hPad: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(.horizontal, hPad).padding(.vertical, vPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 0.5))
    }
}

/// Uppercase accent-blue title, with an optional trailing value.
struct CardTitle<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased()).font(.system(size: 13, weight: .regular)).foregroundStyle(Theme.accent)
            Spacer(minLength: 6)
            trailing
        }
    }
}
extension CardTitle where Trailing == EmptyView {
    init(_ title: String) { self.title = title; self.trailing = EmptyView() }
}
extension CardTitle where Trailing == ValueLabel {
    init(_ title: String, value: String, unit: String = "") {
        self.title = title; self.trailing = ValueLabel(value: value, unit: unit, size: 13)
    }
}

/// A value with a smaller trailing unit: "4.9" + "GB". Numbers are monospaced so columns align.
struct ValueLabel: View {
    var value: String
    var unit: String = ""
    var size: CGFloat = 12.5
    var weight: Font.Weight = .regular
    var body: some View {
        let v = Text(value).font(.system(size: size, weight: weight).monospacedDigit())
        let u = unit.isEmpty ? Text("") : Text((["%", "°", "×"].contains(unit) ? "" : " ") + unit).font(.system(size: size * 0.74, weight: .medium))
        Text("\(v)\(u)").lineLimit(1)
    }
}
extension ValueLabel {
    init(_ parts: (String, String), size: CGFloat = 12.5, weight: Font.Weight = .regular) {
        self.init(value: parts.0, unit: parts.1, size: size, weight: weight)
    }
}

/// Dot, name and right-aligned value — the legend rows used under graphs and rings.
struct LegendRow: View {
    var color: Color?
    var name: String
    var value: ValueLabel
    var nameColor: Color = .secondary
    var body: some View {
        HStack(spacing: 7) {
            if let color { Circle().fill(color).frame(width: 9, height: 9) }
            Text(name).font(.system(size: 12.5)).foregroundStyle(nameColor).lineLimit(1)
            Spacer(minLength: 6)
            value
        }
        .hoverHighlight()
    }
}

/// Plain label / value row.
struct InfoRow: View {
    var label: String
    var value: String
    var unit: String = ""
    var body: some View {
        HStack {
            Text(label).font(.system(size: 12.5)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            ValueLabel(value: value, unit: unit).truncationMode(.middle)
        }
        .hoverHighlight()
    }
}

// MARK: - Bar histories

private let barW: CGFloat = 2, barGap: CGFloat = 1

/// One thin bar per sample, newest on the right. Layers are stacked bottom-up.
struct BarHistory: View {
    var layers: [[Double]]
    var colors: [Color]
    var maxValue: Double
    var body: some View {
        Canvas { ctx, size in
            let step = barW + barGap
            let fit = max(1, Int((size.width + barGap) / step))
            let n = min(fit, layers.map(\.count).max() ?? 0)
            guard n > 0 else { return }
            var cum = [Double](repeating: 0, count: n)
            for (li, layer) in layers.enumerated() {
                let vals = Array(layer.suffix(n))
                let pad = n - vals.count
                var path = Path()
                for i in 0..<n {
                    let v = i >= pad ? max(0, vals[i - pad]) : 0
                    let lo = cum[i], hi = lo + v
                    cum[i] = hi
                    guard v > 0 else { continue }
                    let y1 = size.height * CGFloat(1 - min(1, hi / maxValue))
                    let y0 = size.height * CGFloat(1 - min(1, lo / maxValue))
                    let x = size.width - CGFloat(n - i) * step + barGap
                    path.addRect(CGRect(x: x, y: y1, width: barW, height: max(1, y0 - y1)))
                }
                ctx.fill(path, with: .color(colors[min(li, colors.count - 1)]))
            }
        }
    }
}

/// Up bars above the axis, down bars below it.
struct MirroredBars: View {
    var up: [Double]
    var down: [Double]
    var scale: Double
    var upColor: Color
    var downColor: Color
    var body: some View {
        Canvas { ctx, size in
            let step = barW + barGap
            let fit = max(1, Int((size.width + barGap) / step))
            let n = min(fit, max(up.count, down.count))
            guard n > 0, scale > 0 else { return }
            let mid = size.height / 2, half = mid - 1
            func draw(_ arr: [Double], _ color: Color, _ dir: CGFloat) {
                let vals = Array(arr.suffix(n)), pad = n - vals.count
                var path = Path()
                for i in 0..<n {
                    let v = i >= pad ? max(0, vals[i - pad]) : 0
                    let h = max(1, half * CGFloat(min(1, v / scale)))
                    let x = size.width - CGFloat(n - i) * step + barGap
                    path.addRect(CGRect(x: x, y: dir < 0 ? mid - h : mid, width: barW, height: h))
                }
                ctx.fill(path, with: .color(color))
            }
            draw(up, upColor, -1)
            draw(down, downColor, 1)
        }
    }
}

// MARK: - Rings

/// Ring gauge made of consecutive arc segments (fractions of a full turn) starting at 12 o'clock.
struct SegmentRing<Center: View>: View {
    var segments: [(Double, Color)]
    var lineWidth: CGFloat
    @ViewBuilder var center: Center
    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let r = (min(size.width, size.height) - lineWidth) / 2
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                var track = Path(); track.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                ctx.stroke(track, with: .color(Theme.ringTrack), lineWidth: lineWidth)
                var start = -90.0
                for (frac, color) in segments where frac > 0 {
                    let sweep = max(1.5, min(1, frac) * 360)
                    var p = Path()
                    p.addArc(center: c, radius: r, startAngle: .degrees(start), endAngle: .degrees(min(start + sweep, 270)), clockwise: false)
                    ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    start += frac * 360
                }
            }
            center
        }
    }
}
extension SegmentRing where Center == EmptyView {
    init(segments: [(Double, Color)], lineWidth: CGFloat) { self.init(segments: segments, lineWidth: lineWidth) { EmptyView() } }
}

/// A single-colour usage ring with a big centre value and a caption (GPU 17%, MEM 23%…).
struct GaugeRing: View {
    var fraction: Double
    var color: Color
    var value: String
    var unit: String
    var caption: String
    var lineWidth: CGFloat = 5
    var valueSize: CGFloat = 19
    var body: some View {
        SegmentRing(segments: [(fraction, color)], lineWidth: lineWidth) {
            VStack(spacing: -1) {
                ValueLabel(value: value, unit: unit, size: valueSize, weight: .medium)
                Text(caption).font(.system(size: valueSize * 0.58, weight: .regular)).foregroundStyle(.secondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
