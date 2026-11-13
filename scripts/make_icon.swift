import AppKit

// Draws the Clamshell icon: a screen above a keyboard deck, split by the hinge.
func render(side: Int, macStyle: Bool) -> Data {
    let s = CGFloat(side)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    var canvas = CGRect(x: 0, y: 0, width: s, height: s)
    if macStyle {
        canvas = canvas.insetBy(dx: s * 0.1, dy: s * 0.1)
        ctx.addPath(CGPath(roundedRect: canvas, cornerWidth: canvas.width * 0.225, cornerHeight: canvas.width * 0.225, transform: nil))
        ctx.clip()
    }
    let colors = [CGColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1), CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.maxY), end: CGPoint(x: 0, y: canvas.minY), options: [])

    let w = canvas.width
    let bodyW = w * 0.56, halfH = w * 0.29, gap = w * 0.022
    let x = canvas.midX - bodyW / 2
    let radius = w * 0.045
    // Screen (top half)
    let screen = CGRect(x: x, y: canvas.midY + gap / 2, width: bodyW, height: halfH)
    ctx.setFillColor(CGColor(gray: 0.96, alpha: 1))
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
    // Deck (bottom half)
    let deck = CGRect(x: x, y: canvas.midY - gap / 2 - halfH, width: bodyW, height: halfH)
    ctx.setFillColor(CGColor(gray: 0.30, alpha: 1))
    ctx.addPath(CGPath(roundedRect: deck, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
    // Keys
    ctx.setFillColor(CGColor(gray: 0.96, alpha: 1))
    let cols = 7, rows = 3
    let padX = bodyW * 0.09, top = deck.maxY - halfH * 0.13
    let keyW = (bodyW - padX * 2) / CGFloat(cols)
    let keyH = halfH * 0.15
    for r in 0..<rows {
        for c in 0..<cols {
            let k = CGRect(x: x + padX + CGFloat(c) * keyW, y: top - CGFloat(r + 1) * keyH * 1.35, width: keyW, height: keyH)
                .insetBy(dx: keyW * 0.14, dy: 0)
            ctx.addPath(CGPath(roundedRect: k, cornerWidth: keyH * 0.3, cornerHeight: keyH * 0.3, transform: nil))
        }
    }
    ctx.fillPath()
    // Trackpad
    let pad = CGRect(x: deck.midX - bodyW * 0.2, y: deck.minY + halfH * 0.09, width: bodyW * 0.4, height: halfH * 0.2)
    ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
    ctx.addPath(CGPath(roundedRect: pad, cornerWidth: pad.height * 0.3, cornerHeight: pad.height * 0.3, transform: nil))
    ctx.fillPath()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let ios = root.appendingPathComponent("iOS/Assets.xcassets/AppIcon.appiconset")
try render(side: 1024, macStyle: false).write(to: ios.appendingPathComponent("icon-1024.png"))
try #"{"images":[{"filename":"icon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}"#
    .write(to: ios.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

let mac = root.appendingPathComponent("Host/Assets.xcassets/AppIcon.appiconset")
var images: [String] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon-\(points)@\(scale)x.png"
    try render(side: points * scale, macStyle: true).write(to: mac.appendingPathComponent(name))
    images.append(#"{"filename":"\#(name)","idiom":"mac","scale":"\#(scale)x","size":"\#(points)x\#(points)"}"#)
}
try "{\"images\":[\(images.joined(separator: ","))],\"info\":{\"author\":\"xcode\",\"version\":1}}"
    .write(to: mac.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
for dir in ["iOS/Assets.xcassets", "Host/Assets.xcassets"] {
    try #"{"info":{"author":"xcode","version":1}}"#.write(to: root.appendingPathComponent(dir + "/Contents.json"), atomically: true, encoding: .utf8)
}
print("icons written")
