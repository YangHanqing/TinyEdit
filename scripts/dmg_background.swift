// Draws the DMG window background: an arrow from the app to Applications and a one-line hint.
// Usage: swift scripts/dmg_background.swift OUT.png SCALE   (660 x 400 pt; release.sh makes 1x and 2x)
// The icon centres it points between are set in dmg_dsstore.swift: (170, 190) and (490, 190), from the top left.
import AppKit
let args = CommandLine.arguments
let scale = Double(args[2])!
let width = 660.0, height = 400.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSColor(srgbRed: 0.965, green: 0.965, blue: 0.97, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

// Between the two 128 pt icons, level with their centres (y 190 from the top).
let arrowY = height - 190, from = 262.0, to = 398.0
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: from, y: arrowY))
arrow.line(to: NSPoint(x: to, y: arrowY))
arrow.move(to: NSPoint(x: to - 16, y: arrowY + 16))
arrow.line(to: NSPoint(x: to, y: arrowY))
arrow.line(to: NSPoint(x: to - 16, y: arrowY - 16))
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(srgbRed: 0.6, green: 0.6, blue: 0.63, alpha: 1).setStroke()
arrow.stroke()

func centred(_ text: String, size: CGFloat, weight: NSFont.Weight, gray: CGFloat, baseline: Double) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(white: gray, alpha: 1),
        .paragraphStyle: style,
    ]
    NSAttributedString(string: text, attributes: attributes)
        .draw(in: NSRect(x: 0, y: baseline, width: width, height: size * 1.5))
}
centred("将 TinyEdit 拖到“应用程序”文件夹即可完成安装", size: 15, weight: .medium, gray: 0.25, baseline: 62)
centred("Drag TinyEdit to Applications to install", size: 12, weight: .regular, gray: 0.45, baseline: 40)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
