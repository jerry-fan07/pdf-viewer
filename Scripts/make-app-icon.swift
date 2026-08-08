#!/usr/bin/env swift
//
// Draws the app icon and writes every size the macOS asset catalog wants.
// Committed so the icon is reproducible rather than a binary nobody can edit:
//
//     swift Scripts/make-app-icon.swift ClaudePDF/Assets.xcassets/AppIcon.appiconset
//
// The mark is the app in one image — a page, and a question about it: a white
// document sheet with a folded corner over an indigo squircle, with an amber
// speech bubble overlapping the lower-right. Everything is expressed as a
// fraction of the canvas so all ten sizes are the same drawing, not ten crops.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sizes = [16, 32, 64, 128, 256, 512, 1024]

func draw(size: Int) -> CGImage? {
    let s = CGFloat(size)
    guard let context = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // macOS icons sit inset in their canvas rather than filling it.
    let inset = s * 0.09
    let plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = CGPath(roundedRect: plate,
                          cornerWidth: plate.width * 0.225,
                          cornerHeight: plate.height * 0.225,
                          transform: nil)

    context.saveGState()
    context.addPath(squircle)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.286, green: 0.298, blue: 0.702, alpha: 1),   // indigo
            CGColor(red: 0.161, green: 0.180, blue: 0.451, alpha: 1),   // deeper indigo
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: []
    )
    context.restoreGState()

    // The page: a sheet with the top-right corner folded back.
    let page = CGRect(x: s * 0.28, y: s * 0.235, width: s * 0.375, height: s * 0.5)
    let fold = page.width * 0.30

    let sheet = CGMutablePath()
    sheet.move(to: CGPoint(x: page.minX, y: page.minY))
    sheet.addLine(to: CGPoint(x: page.maxX, y: page.minY))
    sheet.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    sheet.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    sheet.addLine(to: CGPoint(x: page.minX, y: page.maxY))
    sheet.closeSubpath()

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.addPath(sheet)
    context.fillPath()

    // The fold itself, a shade darker so the corner reads as turned.
    context.setFillColor(CGColor(red: 0.827, green: 0.843, blue: 0.902, alpha: 1))
    context.move(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    context.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    context.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
    context.closePath()
    context.fillPath()

    // Text lines. The shortest one sits last, so the block reads as a paragraph.
    context.setFillColor(CGColor(red: 0.62, green: 0.647, blue: 0.737, alpha: 1))
    let lineHeight = page.height * 0.055
    let lineGap = page.height * 0.105
    let lineInset = page.width * 0.14
    for (index, widthFraction) in [0.72, 0.72, 0.72, 0.44].enumerated() {
        let y = page.maxY - fold - lineGap * CGFloat(index + 1)
        let rect = CGRect(x: page.minX + lineInset, y: y,
                          width: page.width * widthFraction, height: lineHeight)
        context.addPath(CGPath(roundedRect: rect,
                               cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2,
                               transform: nil))
        context.fillPath()
    }

    // The question: an amber bubble overlapping the page's lower-right.
    let bubble = CGRect(x: s * 0.505, y: s * 0.215, width: s * 0.30, height: s * 0.235)
    context.setFillColor(CGColor(red: 0.898, green: 0.573, blue: 0.169, alpha: 1))
    context.addPath(CGPath(roundedRect: bubble,
                           cornerWidth: bubble.height * 0.32,
                           cornerHeight: bubble.height * 0.32,
                           transform: nil))
    context.fillPath()

    // Bubble tail.
    context.move(to: CGPoint(x: bubble.minX + bubble.width * 0.22, y: bubble.minY + 1))
    context.addLine(to: CGPoint(x: bubble.minX + bubble.width * 0.12, y: bubble.minY - bubble.height * 0.30))
    context.addLine(to: CGPoint(x: bubble.minX + bubble.width * 0.50, y: bubble.minY + 1))
    context.closePath()
    context.fillPath()

    // Three dots — legible even at 16pt, where a glyph would turn to mush.
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    let dot = bubble.height * 0.145
    for index in 0..<3 {
        let x = bubble.midX + CGFloat(index - 1) * dot * 2.1 - dot / 2
        context.fillEllipse(in: CGRect(x: x, y: bubble.midY - dot / 2, width: dot, height: dot))
    }

    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { throw NSError(domain: "icon", code: 1) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "icon", code: 2) }
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1]
                 : "ClaudePDF/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for size in sizes {
    guard let image = draw(size: size) else { fatalError("could not draw \(size)") }
    try write(image, to: output.appendingPathComponent("icon_\(size).png"))
    print("wrote icon_\(size).png")
}
