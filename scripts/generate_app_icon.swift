#!/usr/bin/env swift
import AppKit
import Foundation

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath)
    .appendingPathComponent("MedNotes/Assets.xcassets/AppIcon.appiconset")

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func makeMaster(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let ctx = NSGraphicsContext.current!.cgContext
        let colors = [
            NSColor(srgbRed: 0.02, green: 0.38, blue: 0.36, alpha: 1).cgColor,
            NSColor(srgbRed: 0.08, green: 0.58, blue: 0.53, alpha: 1).cgColor,
            NSColor(srgbRed: 0.18, green: 0.72, blue: 0.64, alpha: 1).cgColor
        ]
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: [0, 0.55, 1]
        )!
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: size),
            end: CGPoint(x: size, y: 0),
            options: []
        )

        let highlight = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor.white.withAlphaComponent(0.22).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor
            ] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawLinearGradient(
            highlight,
            start: CGPoint(x: size * 0.5, y: size),
            end: CGPoint(x: size * 0.5, y: size * 0.45),
            options: []
        )

        let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: "stethoscope", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return true }
        let symbolSize = symbol.size
        let origin = NSPoint(
            x: (size - symbolSize.width) / 2,
            y: (size - symbolSize.height) / 2 - size * 0.02
        )
        symbol.draw(in: NSRect(origin: origin, size: symbolSize))
        return true
    }
}

func pngData(from image: NSImage, pixelSize: Int) -> Data {
    let scaled = NSImage(size: NSSize(width: pixelSize, height: pixelSize), flipped: false) { rect in
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        return true
    }
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    scaled.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

struct IconSlot {
    let idiomSize: String
    let scale: String
    let pixels: Int
    let filename: String
}

let slots: [IconSlot] = [
    .init(idiomSize: "16x16", scale: "1x", pixels: 16, filename: "icon_16.png"),
    .init(idiomSize: "16x16", scale: "2x", pixels: 32, filename: "icon_16@2x.png"),
    .init(idiomSize: "32x32", scale: "1x", pixels: 32, filename: "icon_32.png"),
    .init(idiomSize: "32x32", scale: "2x", pixels: 64, filename: "icon_32@2x.png"),
    .init(idiomSize: "128x128", scale: "1x", pixels: 128, filename: "icon_128.png"),
    .init(idiomSize: "128x128", scale: "2x", pixels: 256, filename: "icon_128@2x.png"),
    .init(idiomSize: "256x256", scale: "1x", pixels: 256, filename: "icon_256.png"),
    .init(idiomSize: "256x256", scale: "2x", pixels: 512, filename: "icon_256@2x.png"),
    .init(idiomSize: "512x512", scale: "1x", pixels: 512, filename: "icon_512.png"),
    .init(idiomSize: "512x512", scale: "2x", pixels: 1024, filename: "icon_512@2x.png"),
]

let master = makeMaster(size: 1024)
var imagesJSON: [[String: String]] = []
for slot in slots {
    let url = outputDir.appendingPathComponent(slot.filename)
    try pngData(from: master, pixelSize: slot.pixels).write(to: url)
    imagesJSON.append([
        "filename": slot.filename,
        "idiom": "mac",
        "scale": slot.scale,
        "size": slot.idiomSize
    ])
}

let catalog: [String: Any] = [
    "images": imagesJSON,
    "info": ["author": "xcode", "version": 1]
]
let data = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
try data.write(to: outputDir.appendingPathComponent("Contents.json"))
print("Wrote AppIcon.appiconset to \(outputDir.path)")
