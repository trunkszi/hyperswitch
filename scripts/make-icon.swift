#!/usr/bin/env swift
import AppKit

let outputRoot = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = outputRoot.appendingPathComponent("HyperSwitch.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let inset: CGFloat = 0.098

func draw(size: CGFloat) -> NSBitmapImageRep? {
    let pixels = Int(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: size, height: size)

    guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }

    let context = graphics.cgContext
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let margin = size * inset
    let plate = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let radius = plate.width * 0.2237
    let plateePath = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    context.saveGState()
    plateePath.addClip()
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.42, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.19, green: 0.24, blue: 0.78, alpha: 1),
    ])
    gradient?.draw(in: plate, angle: -90)

    let highlight = NSGradient(colors: [
        NSColor(white: 1, alpha: 0.30),
        NSColor(white: 1, alpha: 0),
    ])
    highlight?.draw(in: CGRect(x: plate.minX, y: plate.midY,
                               width: plate.width, height: plate.height / 2), angle: -90)
    context.restoreGState()

    let cardWidth = plate.width * 0.50
    let cardHeight = cardWidth * 0.66
    let step = plate.width * 0.085
    let cardRadius = cardWidth * 0.10

    let cards: [(dx: CGFloat, dy: CGFloat, alpha: CGFloat)] = [
        (-step, step, 0.34),
        (0, 0, 0.62),
        (step, -step, 1.0),
    ]

    for card in cards {
        let rect = CGRect(x: plate.midX - cardWidth / 2 + card.dx,
                          y: plate.midY - cardHeight / 2 + card.dy,
                          width: cardWidth, height: cardHeight)
        let path = NSBezierPath(roundedRect: rect, xRadius: cardRadius, yRadius: cardRadius)
        NSColor(white: 1, alpha: card.alpha).setFill()
        path.fill()

        if card.alpha == 1.0 {
            let bar = CGRect(x: rect.minX, y: rect.maxY - rect.height * 0.22,
                             width: rect.width, height: rect.height * 0.22)
            context.saveGState()
            path.addClip()
            NSColor(srgbRed: 0.19, green: 0.24, blue: 0.78, alpha: 0.22).setFill()
            bar.fill()
            context.restoreGState()

            let dot = rect.height * 0.055
            for index in 0..<3 {
                let centre = CGPoint(x: bar.minX + rect.width * 0.09 + CGFloat(index) * dot * 3,
                                     y: bar.midY)
                let circle = NSBezierPath(ovalIn: CGRect(x: centre.x - dot, y: centre.y - dot,
                                                         width: dot * 2, height: dot * 2))
                NSColor(srgbRed: 0.19, green: 0.24, blue: 0.78, alpha: 0.38).setFill()
                circle.fill()
            }
        }
    }

    return rep
}

let variants: [(name: String, points: CGFloat, scale: CGFloat)] = [
    ("icon_16x16", 16, 1), ("icon_16x16@2x", 16, 2),
    ("icon_32x32", 32, 1), ("icon_32x32@2x", 32, 2),
    ("icon_128x128", 128, 1), ("icon_128x128@2x", 128, 2),
    ("icon_256x256", 256, 1), ("icon_256x256@2x", 256, 2),
    ("icon_512x512", 512, 1), ("icon_512x512@2x", 512, 2),
]

for variant in variants {
    let pixels = variant.points * variant.scale
    guard let rep = draw(size: pixels),
          let png = rep.representation(using: .png, properties: [:])
    else {
        print("failed: \(variant.name)")
        continue
    }
    try png.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

print("wrote \(iconset.path)")
