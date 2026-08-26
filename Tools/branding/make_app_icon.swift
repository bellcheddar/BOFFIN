//  make_app_icon.swift
//  Render BOFFIN's app icon at 1024x1024.
//
//      swift Tools/branding/make_app_icon.swift <output.png>
//
//  Generated rather than drawn by hand so it can be regenerated when the
//  palette moves, and so the colours are the app's OWN: the navy and the
//  viridis ramp below are the same values BoffinUI.ScientificPalette ships,
//  which is also what the README's badges use.
//
//  App Store rules the format has to satisfy, none of which are negotiable:
//  1024x1024, sRGB, NO alpha channel, and NO rounded corners -- iOS applies
//  its own mask, and an icon that pre-rounds itself gets a double-rounded
//  corner. An icon with alpha is rejected outright at upload.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024
let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "icon.png"

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// ScientificPalette.navy, and the viridis ramp it uses for sequential data.
let navy = rgb(0x1C_24_4B)
let paper = rgb(0xF7_F7_F7)  // llrNeutral
let viridis: [CGColor] = [
    rgb(0x44_01_54), rgb(0x3B_52_8B), rgb(0x21_91_8C),
    rgb(0x5E_C9_62), rgb(0xFD_E7_25),
]

// `noneSkipLast` rather than `premultipliedLast`: an icon with an alpha
// channel is rejected, and the surest way not to ship one is not to have one.
guard let context = CGContext(
    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("could not create the bitmap context") }

let full = CGRect(x: 0, y: 0, width: side, height: side)
context.setFillColor(navy)
context.fill(full)

// The sequence ruler, which is the app's central metaphor: one track, every
// residue on it. Kept to a band rather than a picture so it still reads as
// something at 60 points.
//
// Inset to 22% of the width, not 12%. iOS masks the icon to a squircle whose
// corner radius is about 22.4% of the side, so anything closer to an edge than
// that is liable to be cut where it passes a corner. The first version ran the
// band from 12% to 88% at a tenth of the height from the bottom and lost its
// end ticks to the mask.
let bandHeight = CGFloat(side) * 0.075
let bandY = CGFloat(side) * 0.240
let ticks = 12
let gap = CGFloat(side) * 0.008
let bandWidth = CGFloat(side) * 0.46
let tickWidth = (bandWidth - gap * CGFloat(ticks - 1)) / CGFloat(ticks)
var x = (CGFloat(side) - bandWidth) / 2
for i in 0..<ticks {
    // Sampled across the ramp so the band reads as a gradient of measurements
    // rather than as decoration.
    let t = Double(i) / Double(ticks - 1)
    let position = t * Double(viridis.count - 1)
    context.setFillColor(viridis[min(Int(position.rounded()), viridis.count - 1)])
    context.fill(CGRect(x: x, y: bandY, width: tickWidth, height: bandHeight))
    x += tickWidth + gap
}

// The letter. Drawn through CoreText rather than as a path so it picks up the
// system face at the weight the rest of the app uses.
let font = NSFont.systemFont(ofSize: CGFloat(side) * 0.54, weight: .bold)
let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor(cgColor: paper)!,
]
let line = CTLineCreateWithAttributedString(
    NSAttributedString(string: "B", attributes: attributes))
let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
context.textPosition = CGPoint(
    x: (CGFloat(side) - bounds.width) / 2 - bounds.minX,
    // The letter and the band are one group, positioned together rather than
    // each to its own taste. Measured rather than eyeballed: the first two
    // attempts left a 13% margin above the group and 23% below, which reads as
    // the mark sliding off the top. Tools/branding/measure_icon.swift prints
    // the content's bounding box so this is checkable instead of arguable.
    y: CGFloat(side) * 0.260 - bounds.minY)
CTLineDraw(line, context)

guard let image = context.makeImage() else { fatalError("no image") }
let url = URL(fileURLWithPath: output)
guard let destination = CGImageDestinationCreateWithURL(
    url as CFURL, "public.png" as CFString, 1, nil)
else { fatalError("no destination") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("write failed") }
print("wrote \(output) at \(side)x\(side)")
