// Draws the NotchHub app icon: Claude's orange, a notch panel hanging from the top,
// and Claude Code's pixel mascot inside it.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"

let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
    guard let context = NSGraphicsContext.current?.cgContext else { return false }

    // macOS icon grid: an 824 pt rounded square centred on the 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Soft drop shadow, as on system icons.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    context.addPath(squircle)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(squircle)
    context.clip()

    // Background: Claude orange, lighter at the top.
    let colors = [
        NSColor(srgbRed: 0.93, green: 0.58, blue: 0.45, alpha: 1).cgColor,
        NSColor(srgbRed: 0.80, green: 0.38, blue: 0.24, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])

    // Gentle top sheen on the background only.
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.midY), options: [])

    // The notch panel: a narrow neck from the top edge that widens into a rounded panel.
    let neckWidth: CGFloat = 290, neckHeight: CGFloat = 120
    let panel = CGRect(x: body.midX - 330, y: body.minY + neckHeight, width: 660, height: 560)
    let shape = CGMutablePath()
    let neckLeft = body.midX - neckWidth / 2, neckRight = body.midX + neckWidth / 2
    let flare: CGFloat = 40, shoulder: CGFloat = 80, bottom: CGFloat = 130
    shape.move(to: CGPoint(x: neckLeft, y: body.minY - 2))
    shape.addLine(to: CGPoint(x: neckLeft, y: panel.minY - flare))
    shape.addQuadCurve(to: CGPoint(x: neckLeft - flare, y: panel.minY), control: CGPoint(x: neckLeft, y: panel.minY))
    shape.addLine(to: CGPoint(x: panel.minX + shoulder, y: panel.minY))
    shape.addQuadCurve(to: CGPoint(x: panel.minX, y: panel.minY + shoulder), control: CGPoint(x: panel.minX, y: panel.minY))
    shape.addLine(to: CGPoint(x: panel.minX, y: panel.maxY - bottom))
    shape.addQuadCurve(to: CGPoint(x: panel.minX + bottom, y: panel.maxY), control: CGPoint(x: panel.minX, y: panel.maxY))
    shape.addLine(to: CGPoint(x: panel.maxX - bottom, y: panel.maxY))
    shape.addQuadCurve(to: CGPoint(x: panel.maxX, y: panel.maxY - bottom), control: CGPoint(x: panel.maxX, y: panel.maxY))
    shape.addLine(to: CGPoint(x: panel.maxX, y: panel.minY + shoulder))
    shape.addQuadCurve(to: CGPoint(x: panel.maxX - shoulder, y: panel.minY), control: CGPoint(x: panel.maxX, y: panel.minY))
    shape.addLine(to: CGPoint(x: neckRight + flare, y: panel.minY))
    shape.addQuadCurve(to: CGPoint(x: neckRight, y: panel.minY - flare), control: CGPoint(x: neckRight, y: panel.minY))
    shape.addLine(to: CGPoint(x: neckRight, y: body.minY - 2))
    shape.closeSubpath()

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 16), blur: 40, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    context.addPath(shape)
    context.setFillColor(NSColor(white: 0.04, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()

    // Claude Code's mascot, in its terminal orange, inside the panel.
    let rows = [
        "...############...",
        "...##.######.##...",
        ".################.",
        "...############...",
        "....#.#....#.#....",
    ]
    let pixel: CGFloat = 30
    let mascot = CGSize(width: 18 * pixel, height: 5 * pixel * 2)
    let origin = CGPoint(x: panel.midX - mascot.width / 2, y: panel.midY - mascot.height / 2 + 10)
    context.setFillColor(NSColor(srgbRed: 0.91, green: 0.53, blue: 0.39, alpha: 1).cgColor)
    for (y, row) in rows.enumerated() {
        for (x, cell) in row.enumerated() where cell == "#" {
            context.fill(CGRect(x: origin.x + CGFloat(x) * pixel, y: origin.y + CGFloat(y) * pixel * 2, width: pixel, height: pixel * 2))
        }
    }

    // A little status light on the panel, like the notch showing Claude at work.
    context.setFillColor(NSColor(srgbRed: 0.42, green: 0.85, blue: 0.47, alpha: 1).cgColor)
    context.fillEllipse(in: CGRect(x: panel.maxX - 104, y: panel.minY + 52, width: 34, height: 34))

    context.restoreGState()
    return true
}

guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else { fatalError("could not render icon") }
try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
