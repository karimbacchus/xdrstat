// Turns Resources/AppIcon/source.jpg (icon art on a white background) into a transparent,
// macOS-grid PNG: detects the rounded-square body, masks it, and centres it at 824/1024 with a shadow.
// Usage: swift scripts/make-icon.swift <source.jpg> <out.png>
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("usage: make-icon <src> <out.png>") }
let w = cg.width, h = cg.height
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
// Row 0 of the buffer is the TOP of the image.
func lum(_ x: Int, _ y: Int) -> Int { let i = (y * w + x) * 4; return (Int(px[i]) + Int(px[i+1]) + Int(px[i+2])) / 3 }
// The body has a dark outer rim (< 120) on the sides, while the baked shadow outside it stays lighter.
func rim(_ x: Int, _ y: Int) -> Bool { lum(x, y) < 120 }
// The top edge has no rim; any clear step down from the white background marks it.
func dark(_ x: Int, _ y: Int) -> Bool { lum(x, y) < 230 }

// Body edges: first clearly non-white pixel scanning inward along the centre lines.
// The bottom edge carries a baked drop shadow, so mirror the top margin instead of trusting it.
let midX = w / 2, midY = h / 2
let left = (0..<w).first { rim($0, midY) }!
let right = (0..<w).reversed().first { rim($0, midY) }!
let top = (0..<h).first { dark(midX, $0) }!
let side = right - left
let bodyRect = CGRect(x: left, y: top, width: side, height: side)          // top-left origin
// Corner radius: where the diagonal from the top-left corner first hits the body.
let d = (0..<side).first { dark(left + $0, top + $0) }!
let radius = CGFloat(d) / (1 - 1 / sqrt(2))
print("body \(bodyRect) radius \(Int(radius)) (\(Int(radius / CGFloat(side) * 100))% of side)")

// Output: 1024 canvas, 824 body centred (Apple's macOS icon grid), soft shadow.
let S = 1024, B: CGFloat = 824
let out = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: S * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let dst = CGRect(x: (CGFloat(S) - B) / 2, y: (CGFloat(S) - B) / 2 + 6, width: B, height: B)
let r = radius * B / CGFloat(side)
let shape = CGPath(roundedRect: dst, cornerWidth: r, cornerHeight: r, transform: nil)
out.saveGState()
out.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
out.addPath(shape); out.setFillColor(NSColor.gray.cgColor); out.fillPath()
out.restoreGState()
out.addPath(shape); out.clip()
// Crop the source body (CGImage cropping uses top-left origin) and draw it scaled into the mask.
let crop = cg.cropping(to: bodyRect.insetBy(dx: 1, dy: 1))!
out.interpolationQuality = .high
out.draw(crop, in: dst.insetBy(dx: -1, dy: -1))
let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
