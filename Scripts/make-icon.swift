// Draws the Explorer's icon and writes it as a 1024pt PNG.
//
// Generated rather than checked in as a binary, so that changing the mark is a diff rather
// than an opaque asset swap. `build-app.sh` runs this and hands the result to `iconutil`.
import AppKit
import CoreGraphics
import Foundation

let side = 1024
let scale = CGFloat(side) / 1024

guard let context = CGContext(
    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("could not create a drawing context\n".utf8))
    exit(1)
}

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }

// The macOS icon grid: content sits inside a squircle inset from the canvas, so the icon
// lines up with every other app in the Dock rather than looking a size too large.
let inset: CGFloat = 100 * scale
let plate = CGRect(x: inset, y: inset, width: CGFloat(side) - inset * 2, height: CGFloat(side) - inset * 2)
let squircle = CGPath(roundedRect: plate, cornerWidth: 200 * scale, cornerHeight: 200 * scale, transform: nil)

context.saveGState()
context.addPath(squircle)
context.clip()
let background = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.11, green: 0.16, blue: 0.28, alpha: 1),
        CGColor(red: 0.05, green: 0.07, blue: 0.13, alpha: 1)
    ] as CFArray,
    locations: [0, 1])
if let background {
    context.drawLinearGradient(
        background, start: point(0, 1024), end: point(0, 0), options: [])
}
context.restoreGState()

// A client reaching several servers: one filled node with three edges out to hollow ones.
// The asymmetry is deliberate — a symmetric star reads as a hub, which is the server's
// picture, not the client's.
let origin = point(340, 512)
let peers = [point(660, 730), point(690, 500), point(630, 285)]

/// A point `distance` back along the line from `end` toward `control`.
///
/// The edges stop at the rim of the node they reach rather than at its centre. Drawn to the
/// centre they show through the hollow ring as a stub, which at Dock size reads as a smudge.
func retracted(_ end: CGPoint, toward control: CGPoint, by distance: CGFloat) -> CGPoint {
    let dx = control.x - end.x, dy = control.y - end.y
    let length = (dx * dx + dy * dy).squareRoot()
    guard length > 0 else { return end }
    return CGPoint(x: end.x + dx / length * distance, y: end.y + dy / length * distance)
}

context.setLineCap(.round)
context.setLineWidth(26 * scale)
context.setStrokeColor(CGColor(red: 0.35, green: 0.78, blue: 0.85, alpha: 0.55))
for peer in peers {
    context.move(to: origin)
    // Bowed rather than straight, so three edges from one point stay legible at 32pt.
    let control = CGPoint(x: (origin.x + peer.x) / 2, y: (origin.y + peer.y) / 2 + 70 * scale)
    context.addQuadCurve(to: retracted(peer, toward: control, by: 78 * scale), control: control)
    context.strokePath()
}

context.setFillColor(CGColor(red: 0.42, green: 0.86, blue: 0.92, alpha: 1))
context.fillEllipse(in: CGRect(
    x: origin.x - 88 * scale, y: origin.y - 88 * scale, width: 176 * scale, height: 176 * scale))

context.setStrokeColor(CGColor(red: 0.88, green: 0.92, blue: 0.96, alpha: 1))
context.setLineWidth(30 * scale)
for peer in peers {
    context.strokeEllipse(in: CGRect(
        x: peer.x - 56 * scale, y: peer.y - 56 * scale, width: 112 * scale, height: 112 * scale))
}

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("could not render the icon\n".utf8))
    exit(1)
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let bitmap = NSBitmapImageRep(cgImage: image)
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not encode the icon as PNG\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: output))
