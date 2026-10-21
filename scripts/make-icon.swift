// Draws the NotchHub app icon: Claude's orange spark on black, under a small notch.
// Usage: swift scripts/make-icon.swift <output.png> (scripts/make-icon.sh builds the .icns from it)
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
    guard let context = NSGraphicsContext.current?.cgContext else { return false }

    // macOS icon grid: an 824 pt rounded square centred on the 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Soft drop shadow, as on system icons.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: rgb(0, 0, 0, 0.3))
    context.addPath(squircle)
    context.setFillColor(rgb(0.07, 0.07, 0.08))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(squircle)
    context.clip()

    // The notch: pure black on the near-black tile, hanging from the top edge.
    let width: CGFloat = 300, depth: CGFloat = 96, radius: CGFloat = 44, ear = radius * 0.5
    let left = body.midX - width / 2, right = body.midX + width / 2, top = body.minY - 2, bottom = body.minY + depth
    let notch = CGMutablePath()
    notch.move(to: CGPoint(x: left - ear, y: top))
    notch.addQuadCurve(to: CGPoint(x: left, y: top + ear), control: CGPoint(x: left, y: top))
    notch.addLine(to: CGPoint(x: left, y: bottom - radius))
    notch.addQuadCurve(to: CGPoint(x: left + radius, y: bottom), control: CGPoint(x: left, y: bottom))
    notch.addLine(to: CGPoint(x: right - radius, y: bottom))
    notch.addQuadCurve(to: CGPoint(x: right, y: bottom - radius), control: CGPoint(x: right, y: bottom))
    notch.addLine(to: CGPoint(x: right, y: top + ear))
    notch.addQuadCurve(to: CGPoint(x: right + ear, y: top), control: CGPoint(x: right, y: top))
    notch.closeSubpath()
    context.addPath(notch)
    context.setFillColor(rgb(0, 0, 0))
    context.fillPath()

    // Claude's spark: eight rounded rays of alternating length, flat orange.
    let center = CGPoint(x: body.midX, y: body.midY + 40)
    let reach: CGFloat = 260
    context.setStrokeColor(rgb(0.85, 0.47, 0.34))
    context.setLineWidth(74)
    context.setLineCap(.round)
    for ray in 0..<8 {
        let angle = CGFloat(ray) * .pi / 4 + .pi / 8
        let length = ray % 2 == 0 ? reach : reach * 0.78
        context.move(to: center)
        context.addLine(to: CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length))
    }
    context.strokePath()

    context.restoreGState()
    return true
}

guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else { fatalError("could not render icon") }
try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
