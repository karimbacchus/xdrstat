// Cuts the round gauge out of the legacy icon art as a transparent layer for the Liquid Glass icon.
//   swift scripts/make-icon-layer.swift Resources/AppIcon/icon-1024.png Resources/AppIcon.icon/Assets/gauge.png
// The gauge's dark bezel is found by scanning outwards from the centre for the bright, unsaturated frame.
import AppKit
let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("usage: make-icon-layer in.png out.png") }
let n = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(src, in: CGRect(x: 0, y: 0, width: n, height: n))
let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
func isFrame(_ x: Int, _ y: Int) -> Bool {   // silver: bright and grey
    let i = (y * n + x) * 4
    let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
    return min(r, g, b) > 120 && max(r, g, b) - min(r, g, b) < 28
}
func edge(_ dx: Int, _ dy: Int) -> Int {
    var run = 0
    for d in 150..<500 {
        if isFrame(512 + dx * d, 512 + dy * d) { run += 1; if run >= 6 { return d - 5 } } else { run = 0 }
    }
    return 345
}
let left = edge(-1, 0), right = edge(1, 0), up = edge(0, 1), down = edge(0, -1)   // bitmap rows run top-down from the data pointer
let cx = 512.0 + Double(right - left) / 2, cyRow = 512.0 + Double(up - down) / 2
let radius = Double(left + right + up + down) / 4 - 1.5
print("gauge centre (\(cx), row \(cyRow)) radius \(radius)")
// Draw the gauge centred on a fresh canvas at a size that suits the icon grid, clipped to a circle.
let target = 372.0                                   // radius on the 1024 canvas
let scale = target / radius
let out = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
out.interpolationQuality = .high
out.addEllipse(in: CGRect(x: 512 - target, y: 512 - target, width: target * 2, height: target * 2))
out.clip()
let cyUp = Double(n) - cyRow                          // CG user space is y-up
out.translateBy(x: 512, y: 512); out.scaleBy(x: scale, y: scale); out.translateBy(x: -cx, y: -cyUp)
out.draw(src, in: CGRect(x: 0, y: 0, width: n, height: n))
let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
