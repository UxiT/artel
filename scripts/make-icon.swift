// Draws Artel's app icon (1024×1024 PNG): a dark tile with a 2×2 grid of session cards,
// one of them highlighted orange — "this agent is waiting for you".
// Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824 pt tile centred, continuous-ish corners, soft drop shadow.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
color(0x161A24).setFill()
tilePath.fill()
ctx.restoreGState()
ctx.saveGState()
tilePath.addClip()
NSGradient(colors: [color(0x2A3142), color(0x12151D)])!.draw(in: tile, angle: -90)
// Subtle top sheen.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
ctx.restoreGState()
color(0xFFFFFF, 0.08).setStroke()
tilePath.lineWidth = 4
tilePath.stroke()

// 2×2 session cards.
let pad: CGFloat = 128, gap: CGFloat = 44
let cardW = (tile.width - pad * 2 - gap) / 2
let cardH = (tile.height - pad * 2 - gap) / 2
struct Card { var col: Int; var row: Int; var accent: NSColor; var waiting: Bool }
let cards = [
    Card(col: 0, row: 1, accent: color(0x4C8DFF), waiting: false),   // working (blue)
    Card(col: 1, row: 1, accent: color(0xFF9F2E), waiting: true),    // waiting for answer (orange)
    Card(col: 0, row: 0, accent: color(0x34C77B), waiting: false),   // finished (green)
    Card(col: 1, row: 0, accent: color(0x4C8DFF), waiting: false),
]
for c in cards {
    let r = NSRect(x: tile.minX + pad + CGFloat(c.col) * (cardW + gap),
                   y: tile.minY + pad + CGFloat(c.row) * (cardH + gap), width: cardW, height: cardH)
    let path = NSBezierPath(roundedRect: r, xRadius: 40, yRadius: 40)
    if c.waiting {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 46, color: c.accent.withAlphaComponent(0.9).cgColor)
        color(0x0B0D12).setFill()
        path.fill()
        ctx.restoreGState()
    } else {
        color(0x0B0D12, 0.92).setFill()
        path.fill()
    }
    // Header strip with status dot.
    ctx.saveGState()
    path.addClip()
    color(0xFFFFFF, 0.06).setFill()
    NSRect(x: r.minX, y: r.maxY - 62, width: r.width, height: 62).fill()
    ctx.restoreGState()
    c.accent.setFill()
    NSBezierPath(ovalIn: NSRect(x: r.minX + 30, y: r.maxY - 46, width: 30, height: 30)).fill()
    // Terminal lines.
    let widths: [CGFloat] = c.waiting ? [0.55] : [0.62, 0.44, 0.52]
    for (i, w) in widths.enumerated() {
        let line = NSRect(x: r.minX + 30, y: r.maxY - 112 - CGFloat(i) * 42, width: (r.width - 60) * w, height: 18)
        color(0xFFFFFF, i == 0 ? 0.42 : 0.24).setFill()
        NSBezierPath(roundedRect: line, xRadius: 9, yRadius: 9).fill()
    }
    if c.waiting {
        // "?" bubble — the agent asked something.
        let bubble = NSRect(x: r.maxX - 150, y: r.minY + 40, width: 108, height: 88)
        c.accent.setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 30, yRadius: 30).fill()
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: bubble.minX + 24, y: bubble.minY + 6))
        tail.line(to: NSPoint(x: bubble.minX + 10, y: bubble.minY - 22))
        tail.line(to: NSPoint(x: bubble.minX + 50, y: bubble.minY + 4))
        tail.close()
        tail.fill()
        let q = NSAttributedString(string: "?", attributes: [
            .font: NSFont.systemFont(ofSize: 70, weight: .heavy), .foregroundColor: color(0x1A1206)])
        let qs = q.size()
        q.draw(at: NSPoint(x: bubble.midX - qs.width / 2, y: bubble.midY - qs.height / 2 + 2))
        c.accent.setStroke()
        path.lineWidth = 9
        path.stroke()
    } else {
        color(0xFFFFFF, 0.10).setStroke()
        path.lineWidth = 3
        path.stroke()
    }
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
