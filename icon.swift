// Draws Mem's app icon into an .iconset (run by `make`; iconutil turns it into Mem.icns).
// The motif is the app's own memory bar: wired, app, compressed, cached, free.

import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Mem.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func draw(size px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let s = CGFloat(px) / 1024   // design on a 1024 grid

    // Body: macOS icon grid (824 px squircle-ish rounded rect, centered).
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: color(0, 0, 0, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0.11, 0.11, 0.13))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0.20, 0.20, 0.23), color(0.08, 0.08, 0.10)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // Three stacked bars, like memory filling up; the bottom one is the full breakdown.
    let segments: [(CGFloat, CGColor)] = [
        (0.15, color(1.0, 0.62, 0.04)),   // wired
        (0.38, color(0.04, 0.52, 1.0)),   // app
        (0.10, color(0.75, 0.35, 0.95)),  // compressed
        (0.17, color(0.56, 0.56, 0.58)),  // cached
    ]
    let barX = 210 * s, barW = 604 * s, barH = 118 * s, radius = 30 * s
    for (i, fill) in [CGFloat(0.42), 0.66, 1.0].enumerated() {
        let y = (590 - CGFloat(i) * 170) * s
        let track = CGPath(roundedRect: CGRect(x: barX, y: y, width: barW, height: barH), cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(track)
        ctx.setFillColor(color(1, 1, 1, 0.08))
        ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(track)
        ctx.clip()
        var x = barX
        for (share, c) in segments {
            let w = barW * share * fill / 0.80
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: x, y: y, width: min(w, barX + barW * fill - x), height: barH))
            x += w
            if x >= barX + barW * fill { break }
        }
        ctx.restoreGState()
    }
    ctx.restoreGState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(size: base * scale).write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    }
}
