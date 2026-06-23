// Generates AIMeter app icon (1024px PNG): a segmented gauge ring on a dark
// rounded-square background. Run: swift make_aimeter_icon.swift  → aimeter-1024.png
import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

// Rounded-square background with a vertical gradient (dark teal → near black).
let pad: CGFloat = 96
let rect = NSRect(x: pad, y: pad, width: S - 2*pad, height: S - 2*pad)
let corner: CGFloat = (S - 2*pad) * 0.2237
let bg = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
bg.addClip()
let grad = NSGradient(colors: [
    NSColor(srgbRed: 0.10, green: 0.20, blue: 0.24, alpha: 1),
    NSColor(srgbRed: 0.04, green: 0.09, blue: 0.12, alpha: 1)
])!
grad.draw(in: bg, angle: -90)

// Segmented gauge ring (4 gaps at 12/3/6/9), filled ~70%.
let center = NSPoint(x: S/2, y: S/2)
let radius: CGFloat = (S - 2*pad) * 0.32
let lineW: CGFloat = radius * 0.34
let fraction: CGFloat = 0.70

// Faint full track
let track = NSBezierPath()
track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
track.lineWidth = lineW
NSColor(white: 1, alpha: 0.16).setStroke()
track.stroke()

// Progress arc (green), from top clockwise
let prog = NSBezierPath()
prog.appendArc(withCenter: center, radius: radius, startAngle: 90,
               endAngle: 90 - fraction * 360, clockwise: true)
prog.lineWidth = lineW
prog.lineCapStyle = .round
NSColor(srgbRed: 0.18, green: 0.82, blue: 0.35, alpha: 1).setStroke()
prog.stroke()

// Draw the 4 gaps as dark notches (matching the background, NOT transparent).
let gapColor = NSColor(srgbRed: 0.07, green: 0.14, blue: 0.18, alpha: 1)
let halfGap: CGFloat = 7
for c in [90, 0, 270, 180] as [CGFloat] {
    let g = NSBezierPath()
    g.appendArc(withCenter: center, radius: radius, startAngle: c - halfGap, endAngle: c + halfGap)
    g.lineWidth = lineW + 8
    gapColor.setStroke(); g.stroke()
}

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "aimeter-1024.png"))
print("ok")
