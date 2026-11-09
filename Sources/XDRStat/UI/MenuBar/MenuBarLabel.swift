// Menu bar labels, drawn with AppKit / Core Graphics into small template bitmaps. OWNER: lead.
//
// Not SwiftUI's ImageRenderer: it renders through Metal (RenderBox), which keeps ~100 MB of graphics
// memory alive for the life of the process and costs far more per frame than a few rects and strings.
// StatusBarController only hands a new image to AppKit when the rendered pixels actually change, since
// every status item update is expensive on recent macOS (it re-snapshots the item for the menu bar).

import AppKit
import CoreText

enum LabelKind: Int, CaseIterable { case cpu, memory, network, sensors }

@MainActor enum MenuBarLabel {
    static let height: CGFloat = 18

    struct Rendered {
        var image: NSImage
        var cgImage: CGImage
        /// Raw pixels, so callers can skip no-op updates.
        var pixels: Data
        /// What VoiceOver says for the item, e.g. "CPU 23%".
        var accessibility: String
    }

    /// Renders one label. `color` black gives a template image (AppKit tints it for the menu bar);
    /// any other colour gives a plain image (site screenshots).
    static func render(_ kind: LabelKind, _ st: MonitorState, scale: CGFloat = 2, color: NSColor = .black) -> Rendered {
        let (items, spacing, spoken) = layout(kind, st)
        let widths = items.map(width)
        let total = max(1, widths.reduce(0, +) + spacing * CGFloat(max(0, items.count - 1)))
        let pw = Int((total * scale).rounded(.up)), ph = Int((height * scale).rounded())
        let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        var x: CGFloat = 0
        for (item, w) in zip(items, widths) {
            draw(item, x: x, in: ctx)
            x += w + spacing
        }
        NSGraphicsContext.restoreGraphicsState()
        if color != .black {
            // Everything is drawn in black; recolour while keeping the alpha.
            ctx.setBlendMode(.sourceIn)
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: total, height: height))
        }
        let cg = ctx.makeImage()!
        let pixels = ctx.data.map { Data(bytes: $0, count: ctx.bytesPerRow * ph) } ?? Data()
        let image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(pw) / scale, height: height))
        image.isTemplate = color == .black
        return Rendered(image: image, cgImage: cg, pixels: pixels, accessibility: spoken)
    }

    // MARK: - Content

    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
    private static let rateFont = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .medium)

    private enum Item {
        case bars([Double], barWidth: CGFloat)              // 14 pt tall meters, 1.5 pt apart
        case text(String, NSFont, box: CGFloat?)            // right-aligned in `box` when given
        case twoLines(String, String, NSFont, box: CGFloat) // right-aligned
        case symbol(String, pointSize: CGFloat)
        case mirrored(down: [Double], up: [Double], scale: Double, size: CGSize)
        case sparkline([Double], size: CGSize)
    }

    private static func layout(_ kind: LabelKind, _ st: MonitorState) -> (items: [Item], spacing: CGFloat, spoken: String) {
        switch kind {
        case .cpu:
            let cpu = st.chip.cpu
            let pctText = String(format: "%.0f%%", cpu.usage * 100)
            let pct = Item.text(pctText, valueFont, box: 36)
            let spoken = "CPU \(pctText)"
            switch st.style {
            case .graph: return ([.bars(cpu.clusters.isEmpty ? [cpu.usage] : cpu.clusters.map(\.usage), barWidth: 4.5), pct], 4, spoken)
            case .text: return ([pct], 0, spoken)
            case .compact: return ([.symbol("cpu", pointSize: 12), pct], 3, spoken)
            }
        case .memory:
            let m = st.memory
            let pctText = String(format: "%.0f%%", m.usedFraction * 100)
            let pct = Item.text(pctText, valueFont, box: 36)
            let spoken = "Memory \(pctText) used"
            switch st.style {
            case .graph: return ([.bars([m.pressure], barWidth: 5), pct], 4, spoken)
            case .text: return ([pct], 0, spoken)
            case .compact: return ([.symbol("memorychip", pointSize: 12), pct], 3, spoken)
            }
        case .network:
            let n = st.network
            let up = Fmt.rate(n.upBytesPerSec), down = Fmt.rate(n.downBytesPerSec)
            let lines = Item.twoLines("↑ " + up, "↓ " + down, rateFont, box: 66)
            let spoken = "Upload \(up), download \(down)"
            switch st.style {
            case .graph:
                // Scaled to what's visible (the last 30 samples), not to a spike that already scrolled away.
                let down = Array(st.netDownHistory.values.suffix(30)), up = Array(st.netUpHistory.values.suffix(30))
                let peak = max(down.max() ?? 0, up.max() ?? 0, 250_000)
                return ([.mirrored(down: down, up: up, scale: Fmt.niceMax(peak), size: CGSize(width: 26, height: 14)), lines], 4, spoken)
            case .text: return ([lines], 0, spoken)
            case .compact: return ([.symbol("arrow.up.arrow.down", pointSize: 11), lines], 3, spoken)
            }
        case .sensors:
            let (vals, pinned) = sensorValues(st)
            let text = Item.text(vals.joined(separator: " "), valueFont, box: nil)
            let spoken = pinned ? "Sensors " + vals.joined(separator: ", ") : "CPU temperature \(vals.joined())"
            // The graph follows the first pinned sensor, or the CPU temperature.
            let history = pinned ? st.pinnedHistory : st.cpuTempHistory
            switch st.style {
            case .graph: return ([.sparkline(Array(history.values.suffix(30)), size: CGSize(width: 24, height: 13)), text], 4, spoken)
            case .text: return ([text], 0, spoken)
            case .compact: return ([.symbol("thermometer.medium", pointSize: 12), text], 2, spoken)
            }
        }
    }

    /// The sensors item's values: pinned sensors (up to four), else the CPU temperature.
    static func sensorValues(_ st: MonitorState) -> (values: [String], pinned: Bool) {
        let s = st.sensors
        if !st.pinnedSensorIDs.isEmpty {
            var byID: [String: Sensor] = [:]
            for x in s.temperatures + s.power + s.voltages + s.currents { byID[x.id] = x }
            let pinned = st.pinnedSensorIDs.compactMap { byID[$0] }
            if !pinned.isEmpty {
                return (pinned.prefix(4).map { x in
                    x.unit == .celsius ? Fmt.temp(x.value, st.unit) : Fmt.sensor(x, unit: st.unit).replacingOccurrences(of: " ", with: "")
                }, true)
            }
        }
        return ([s.cpuTemperature.map { Fmt.temp($0, st.unit) } ?? "--°"], false)
    }

    // MARK: - Measuring

    private static func width(_ item: Item) -> CGFloat {
        switch item {
        case .bars(let v, let w): return CGFloat(v.count) * w + CGFloat(max(0, v.count - 1)) * 1.5
        case .text(let s, let f, let box): return box ?? line(s, f).width
        case .twoLines(_, _, _, let box): return box
        case .symbol(let name, let pt): return symbol(name, pt)?.size.width ?? 0
        case .mirrored(_, _, _, let size), .sparkline(_, let size): return size.width
        }
    }

    private struct Line { var ct: CTLine; var width: CGFloat; var ascent: CGFloat; var descent: CGFloat; var leading: CGFloat }

    private static func line(_ s: String, _ font: NSFont) -> Line {
        let attr = NSAttributedString(string: s, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
        let ct = CTLineCreateWithAttributedString(attr)
        var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(ct, &a, &d, &l))
        return Line(ct: ct, width: w, ascent: a, descent: d, leading: l)
    }

    private static var symbolCache: [String: NSImage] = [:]
    private static func symbol(_ name: String, _ pt: CGFloat) -> NSImage? {
        let key = "\(name)@\(pt)"
        if let i = symbolCache[key] { return i }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pt, weight: .medium))
        symbolCache[key] = img
        return img
    }

    // MARK: - Drawing (non-flipped: y grows upwards from the bottom of the 18 pt strip)

    private static func draw(_ item: Item, x: CGFloat, in ctx: CGContext) {
        ctx.setFillColor(.black)
        ctx.setStrokeColor(.black)
        switch item {
        case .bars(let values, let w):
            for (i, v) in values.enumerated() {
                let bx = x + CGFloat(i) * (w + 1.5)
                miniBar(v, in: CGRect(x: bx, y: (height - 14) / 2, width: w, height: 14), ctx)
            }
        case .text(let s, let font, let box):
            let l = line(s, font)
            let lx = box.map { x + $0 - l.width } ?? x
            drawLine(l, x: lx, baseline: (height - l.ascent + l.descent + l.leading) / 2, ctx)
        case .twoLines(let a, let b, let font, let box):
            let la = line(a, font), lb = line(b, font)
            let lh = la.ascent + la.descent + la.leading
            let top = (height - 2 * lh) / 2                 // distance from the top edge, as a VStack would
            drawLine(la, x: x + box - la.width, baseline: height - top - la.ascent, ctx)
            drawLine(lb, x: x + box - lb.width, baseline: height - top - lh - lb.ascent, ctx)
        case .symbol(let name, let pt):
            guard let img = symbol(name, pt) else { return }
            img.draw(in: NSRect(x: x, y: (height - img.size.height) / 2, width: img.size.width, height: img.size.height))
        case .mirrored(let down, let up, let scale, let size):
            mirrored(down: down, up: up, scale: scale, in: CGRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height), ctx)
        case .sparkline(let values, let size):
            sparkline(values, in: CGRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height), ctx)
        }
    }

    private static func drawLine(_ l: Line, x: CGFloat, baseline: CGFloat, _ ctx: CGContext) {
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(l.ct, ctx)
    }

    private static func miniBar(_ value: Double, in r: CGRect, _ ctx: CGContext) {
        let radius: CGFloat = 1.2
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.28))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        let h = max(1.5, r.height * CGFloat(min(1, max(0, value.isFinite ? value : 0))))
        let fill = CGRect(x: r.minX, y: r.minY, width: r.width, height: h)
        let fr = min(radius, h / 2, r.width / 2)
        ctx.setFillColor(.black)
        ctx.addPath(CGPath(roundedRect: fill, cornerWidth: fr, cornerHeight: fr, transform: nil))
        ctx.fillPath()
    }

    /// Same curve as the panels' graphs: quadratic segments through the midpoints between samples.
    private static func smooth(_ pts: [CGPoint], into p: CGMutablePath, connect: Bool) {
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

    private static func gradient(_ a0: CGFloat, _ a1: CGFloat) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                   colors: [CGColor(gray: 0, alpha: a0), CGColor(gray: 0, alpha: a1)] as CFArray, locations: [0, 1])!
    }

    private static func strokeLine(_ path: CGPath, _ ctx: CGContext) {
        ctx.addPath(path)
        ctx.setLineWidth(1.2)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(.black)
        ctx.strokePath()
    }

    /// Download above the axis, upload below; 30 samples across.
    private static func mirrored(down: [Double], up: [Double], scale: Double, in r: CGRect, _ ctx: CGContext) {
        let capacity = 30
        let mid = r.minY + r.height / 2, half = r.height / 2 - 2
        let step = r.width / CGFloat(capacity - 1)
        for (arr, dir) in [(down, 1.0), (up, -1.0)] where !arr.isEmpty && scale > 0 {
            let off = capacity - arr.count
            let pts = arr.enumerated().map { i, v in
                CGPoint(x: r.minX + CGFloat(max(0, off) + i) * step,
                        y: mid + CGFloat(dir) * CGFloat(min(1, max(0, v / scale))) * half)
            }
            let fill = CGMutablePath()
            smooth(pts, into: fill, connect: false)
            fill.addLine(to: CGPoint(x: pts.last!.x, y: mid)); fill.addLine(to: CGPoint(x: pts.first!.x, y: mid)); fill.closeSubpath()
            ctx.saveGState()
            ctx.addPath(fill); ctx.clip()
            // Faint far from the axis, strong near it.
            let far = CGPoint(x: 0, y: dir > 0 ? r.maxY : r.minY), near = CGPoint(x: 0, y: mid)
            ctx.drawLinearGradient(gradient(0.08, 0.65), start: far, end: near, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
            let line = CGMutablePath(); smooth(pts, into: line, connect: false)
            strokeLine(line, ctx)
        }
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
        ctx.setLineWidth(0.75)
        ctx.move(to: CGPoint(x: r.minX, y: mid)); ctx.addLine(to: CGPoint(x: r.maxX, y: mid))
        ctx.strokePath()
    }

    /// Auto-scaled area sparkline (at least a 6° span, so sensor noise doesn't look like a cliff).
    private static func sparkline(_ values: [Double], in r: CGRect, _ ctx: CGContext) {
        let capacity = 30
        guard !values.isEmpty else {
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.15)); ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: r.minX, y: r.minY + 0.5)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY + 0.5))
            ctx.strokePath()
            return
        }
        let lo = values.min()!, hi = values.max()!
        let span = max(hi - lo, 6)
        let base = (lo + hi) / 2 - span / 2
        let ymax = span * 1.25
        let step = r.width / CGFloat(capacity - 1)
        let off = capacity - values.count
        let pts = values.enumerated().map { i, v in
            CGPoint(x: r.minX + CGFloat(max(0, off) + i) * step,
                    y: r.minY + 1 + CGFloat(min(1, max(0, (v - base + span * 0.15) / ymax))) * (r.height - 2))
        }
        let fill = CGMutablePath()
        smooth(pts, into: fill, connect: false)
        fill.addLine(to: CGPoint(x: pts.last!.x, y: r.minY)); fill.addLine(to: CGPoint(x: pts.first!.x, y: r.minY)); fill.closeSubpath()
        ctx.saveGState()
        ctx.addPath(fill); ctx.clip()
        ctx.drawLinearGradient(gradient(0.55, 0.06), start: CGPoint(x: 0, y: r.maxY), end: CGPoint(x: 0, y: r.minY), options: [])
        ctx.restoreGState()
        let line = CGMutablePath(); smooth(pts, into: line, connect: false)
        strokeLine(line, ctx)
    }
}
