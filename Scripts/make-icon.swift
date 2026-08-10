#!/usr/bin/env swift
// Generates Resources/AppIcon.icns.
//
// The icon is drawn rather than hand-authored so it can be regenerated and tweaked:
//   swift Scripts/make-icon.swift
//
// Shape follows the macOS convention — a superellipse ("squircle") inset inside the
// canvas with a soft drop shadow, not a circular-cornered rectangle.

import AppKit
import CoreGraphics
import Foundation

let repoRoot = URL(fileURLWithPath: CommandLine.arguments.first.map {
    URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path
} ?? ".")
let resources = repoRoot.appendingPathComponent("Resources")
let iconset = repoRoot.appendingPathComponent("build/AppIcon.iconset")

/// Apple's icon silhouette is closer to a superellipse than to a rounded rectangle.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 1440
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
        let y = cy + b * pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func drawIcon(size: CGFloat) -> CGImage? {
    let scale = size / 1024
    guard let context = CGContext(
        data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // Apple's macOS icon grid: an 824x824 body centred in a 1024 canvas, i.e. a 100pt
    // margin. macOS 26 checks artwork against this geometry — anything that overflows
    // it (a baked drop shadow will) is treated as a legacy icon and gets parked on a
    // grey tile instead of being masked to the system shape. So: exact bounds, and no
    // shadow of our own. macOS draws the shadow.
    let inset: CGFloat = 100 * scale
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = squircle(in: body)

    // Blue-to-indigo gradient body.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let colors = [
        NSColor(srgbRed: 0.36, green: 0.68, blue: 1.00, alpha: 1).cgColor,
        NSColor(srgbRed: 0.20, green: 0.44, blue: 0.93, alpha: 1).cgColor,
        NSColor(srgbRed: 0.30, green: 0.24, blue: 0.80, alpha: 1).cgColor,
    ]
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: colors as CFArray, locations: [0, 0.55, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: body.midX, y: body.maxY),
                               end: CGPoint(x: body.midX, y: body.minY),
                               options: [])

    // Soft highlight across the top, so the surface reads as slightly domed.
    let highlight = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [NSColor.white.withAlphaComponent(0.30).cgColor,
                 NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(highlight,
                               start: CGPoint(x: body.midX, y: body.maxY),
                               end: CGPoint(x: body.midX, y: body.midY + body.height * 0.05),
                               options: [])
    context.restoreGState()

    // Hairline rim, which keeps the edge crisp against dark backgrounds.
    context.saveGState()
    context.addPath(shape)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    context.setLineWidth(2.5 * scale)
    context.strokePath()
    context.restoreGState()

    // Glyph: an arrow descending into an open tray — "install this update".
    // Coordinates are fractions of the body so it scales exactly.
    let s = body.width
    func px(_ fx: CGFloat) -> CGFloat { body.minX + fx * s }
    func py(_ fy: CGFloat) -> CGFloat { body.minY + fy * s }

    // The glyph is composited inside a transparency layer so the shadow is applied to
    // it as a whole. Shadowing each piece separately seams the overlaps, and merging
    // them into one path cancels the overlap under the nonzero winding rule.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6 * scale),
                      blur: 18 * scale,
                      color: NSColor(srgbRed: 0.08, green: 0.15, blue: 0.4, alpha: 0.45).cgColor)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.setFillColor(NSColor.white.cgColor)

    // Arrow shaft.
    let shaftWidth = 0.150 * s
    let shaft = CGRect(x: px(0.5) - shaftWidth / 2, y: py(0.560),
                       width: shaftWidth, height: 0.290 * s)
    context.addPath(CGPath(roundedRect: shaft, cornerWidth: shaftWidth / 2,
                           cornerHeight: shaftWidth / 2, transform: nil))
    context.fillPath()

    // Arrowhead, overlapping the shaft so the two read as one form.
    let head = CGMutablePath()
    head.move(to: CGPoint(x: px(0.5), y: py(0.350)))
    head.addLine(to: CGPoint(x: px(0.325), y: py(0.605)))
    head.addLine(to: CGPoint(x: px(0.675), y: py(0.605)))
    head.closeSubpath()
    context.addPath(head)
    context.fillPath()

    // Open tray the arrow points into.
    let trayWidth = 0.60 * s
    let stroke = 0.072 * s
    let tray = CGMutablePath()
    let left = px(0.5) - trayWidth / 2, right = px(0.5) + trayWidth / 2
    let top = py(0.315), bottom = py(0.155)
    tray.move(to: CGPoint(x: left, y: top))
    tray.addLine(to: CGPoint(x: left, y: bottom + stroke / 2))
    tray.addLine(to: CGPoint(x: right, y: bottom + stroke / 2))
    tray.addLine(to: CGPoint(x: right, y: top))
    context.addPath(tray)
    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(stroke)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    context.endTransparencyLayer()
    context.restoreGState()

    return context.makeImage()
}

// Each size is drawn fresh rather than downscaled, so small sizes stay crisp.
let variants: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

for (name, size) in variants {
    guard let image = drawIcon(size: size) else { continue }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try data.write(to: iconset.appendingPathComponent(name))
}

print("wrote \(variants.count) sizes to \(iconset.path)")
