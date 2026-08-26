import AppKit
import Foundation
let url = URL(fileURLWithPath: "/tmp/boffin_icon.png")
let image = NSImage(contentsOf: url)!
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let w = rep.pixelsWide, h = rep.pixelsHigh
var minX = w, maxX = 0, minY = h, maxY = 0
let bg = rep.colorAt(x: 4, y: 4)!
for y in 0..<h {
    for x in 0..<w {
        let c = rep.colorAt(x: x, y: y)!
        let d = abs(c.redComponent - bg.redComponent)
              + abs(c.greenComponent - bg.greenComponent)
              + abs(c.blueComponent - bg.blueComponent)
        if d > 0.08 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
let pct = { (v: Int) in String(format: "%.1f%%", Double(v) / Double(w) * 100) }
print("  content box: x \(pct(minX))..\(pct(maxX))  y(from top) \(pct(minY))..\(pct(maxY))")
print("  horizontal centre \(pct((minX + maxX) / 2))  vertical centre \(pct((minY + maxY) / 2))")
print("  margins: top \(pct(minY))  bottom \(pct(h - maxY))  left \(pct(minX))  right \(pct(w - maxX))")
