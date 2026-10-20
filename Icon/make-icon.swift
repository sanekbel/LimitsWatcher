// Draws the app icon (a usage gauge) and writes Icon/AppIcon.icns.
// Usage: swift Icon/make-icon.swift   (needs only the Command Line Tools; build.sh runs it when the .icns is missing)
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // macOS icon grid: 824pt body centred on a 1024pt canvas, continuous-corner radius ≈ 185.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let background = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [CGColor(srgbRed: 0.20, green: 0.18, blue: 0.42, alpha: 1),
                 CGColor(srgbRed: 0.07, green: 0.08, blue: 0.17, alpha: 1)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Gauge: 240° arc opening downwards, track + coloured fill up to ~68 %.
    let center = CGPoint(x: 512, y: 470)
    let radius: CGFloat = 270
    let lineWidth: CGFloat = 78
    let start = CGFloat.pi * 7 / 6   // 210°, lower left
    let sweep = CGFloat.pi * 4 / 3   // 240° clockwise
    let filled: CGFloat = 0.68

    ctx.setLineCap(.round)
    ctx.setLineWidth(lineWidth)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
    ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: start - sweep, clockwise: true)
    ctx.strokePath()

    // Coloured fill as short segments so the hue runs green → yellow → orange → red along the arc.
    let stops: [(CGFloat, (CGFloat, CGFloat, CGFloat))] = [
        (0.00, (0.20, 0.84, 0.47)), (0.45, (0.98, 0.80, 0.22)),
        (0.75, (1.00, 0.55, 0.20)), (1.00, (0.96, 0.27, 0.30)),
    ]
    func color(at t: CGFloat) -> CGColor {
        for i in 1..<stops.count where t <= stops[i].0 {
            let (t0, a) = stops[i - 1], (t1, b) = stops[i]
            let k = (t - t0) / (t1 - t0)
            return CGColor(srgbRed: a.0 + (b.0 - a.0) * k, green: a.1 + (b.1 - a.1) * k, blue: a.2 + (b.2 - a.2) * k, alpha: 1)
        }
        return CGColor(srgbRed: stops.last!.1.0, green: stops.last!.1.1, blue: stops.last!.1.2, alpha: 1)
    }
    let steps = 120
    for i in 0..<steps {
        let t0 = CGFloat(i) / CGFloat(steps) * filled
        let t1 = CGFloat(i + 1) / CGFloat(steps) * filled
        ctx.setLineCap(i == 0 || i == steps - 1 ? .round : .butt)
        ctx.setStrokeColor(color(at: (t0 + t1) / 2 / 1))
        ctx.addArc(center: center, radius: radius, startAngle: start - sweep * t0, endAngle: start - sweep * t1 - 0.004, clockwise: true)
        ctx.strokePath()
    }

    // Needle pointing at the fill level, with a hub.
    let angle = start - sweep * filled
    let tip = CGPoint(x: center.x + cos(angle) * (radius - 70), y: center.y + sin(angle) * (radius - 70))
    let normal = CGPoint(x: -sin(angle), y: cos(angle))
    let baseHalf: CGFloat = 26
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.move(to: tip)
    ctx.addLine(to: CGPoint(x: center.x + normal.x * baseHalf, y: center.y + normal.y * baseHalf))
    ctx.addLine(to: CGPoint(x: center.x - normal.x * baseHalf, y: center.y - normal.y * baseHalf))
    ctx.closePath()
    ctx.fillPath()
    ctx.fillEllipse(in: CGRect(x: center.x - 52, y: center.y - 52, width: 104, height: 104))
    ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.27, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: center.x - 20, y: center.y - 20, width: 40, height: 40))

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let out = root.appendingPathComponent("AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard task.terminationStatus == 0 else { exit(1) }
print("✓ \(out.path)")
