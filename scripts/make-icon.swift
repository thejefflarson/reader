#!/usr/bin/env swift
import AppKit
import CoreGraphics
import CoreText

// Render Reader's AppIcon — a bold serif "R" in scarlet ink on warm paper,
// seated inside a softly rounded square.
//
// Usage:  swift scripts/make-icon.swift
// Output: Resources/AppIcon.icns (+ the intermediate AppIcon.iconset/)

let paper = CGColor(red: 0xFD/255, green: 0xFC/255, blue: 0xF8/255, alpha: 1)
let ink   = CGColor(red: 0xC8/255, green: 0x1F/255, blue: 0x2E/255, alpha: 1)
let rim   = CGColor(gray: 0, alpha: 0.06)

func drawIcon(pixels: Int) -> Data? {
    let size = CGFloat(pixels)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldSmoothFonts(true)

    // Rounded-square paper. ~8% edge padding (Apple's shadow sits there at
    // small sizes) and ~22% corner radius on the drawn body.
    let inset = size * 0.08
    let body = CGRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
    let radius = body.width * 0.225
    let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.addPath(bodyPath)
    ctx.setFillColor(paper)
    ctx.fillPath()

    ctx.addPath(bodyPath)
    ctx.setStrokeColor(rim)
    ctx.setLineWidth(max(size * 0.004, 0.5))
    ctx.strokePath()

    // Letterform — serif "R" in ink. New York is a variable optical-size
    // face. At ~400pt draw size CoreText would auto-select NewYorkExtraLarge
    // (Didone display cut, aggressive stroke contrast). We pin the optical
    // size to body-text value (17pt) to get NewYorkMedium shapes drawn
    // large. The `.bold` weight gives the glyph icon-weight presence
    // without switching to the Didone display face.
    let letterHeight = body.height * 0.78
    let bodyOpticalSize: CGFloat = 17
    let opsz: UInt32 =
        (UInt32(UInt8(ascii: "o")) << 24) |
        (UInt32(UInt8(ascii: "p")) << 16) |
        (UInt32(UInt8(ascii: "s")) << 8)  |
        UInt32(UInt8(ascii: "z"))

    let systemSerif = NSFont.systemFont(ofSize: letterHeight, weight: .bold)
        .fontDescriptor
        .withDesign(.serif) ?? NSFont.systemFont(ofSize: letterHeight, weight: .bold).fontDescriptor

    let pinnedDescriptor = CTFontDescriptorCreateCopyWithVariation(
        systemSerif as CTFontDescriptor,
        NSNumber(value: opsz) as CFNumber,
        bodyOpticalSize
    )
    let font = CTFontCreateWithFontDescriptor(pinnedDescriptor, letterHeight, nil)
    if pixels == 512 {
        print("using font: \(CTFontCopyPostScriptName(font) as String)")
    }

    let attrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: ink,
    ]
    let attrString = CFAttributedStringCreate(nil, "R" as CFString, attrs as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attrString)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

    let x = body.midX - lineWidth / 2
    let textHeight = ascent + descent
    // Optical centering: capitals read best lifted ~5% of glyph height above
    // geometric center.
    let baselineY = body.midY - textHeight / 2 + descent - size * 0.02

    ctx.textPosition = CGPoint(x: x, y: baselineY)
    CTLineDraw(line, ctx)

    guard let cgImage = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(logical: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

let fm = FileManager.default
let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = cwd.appendingPathComponent("Resources/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for (logical, scale) in sizes {
    let pixels = logical * scale
    let suffix = scale == 1 ? "" : "@\(scale)x"
    let filename = "icon_\(logical)x\(logical)\(suffix).png"
    guard let png = drawIcon(pixels: pixels) else {
        FileHandle.standardError.write(Data("failed to render \(filename)\n".utf8))
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent(filename))
    print("wrote \(filename) (\(pixels)×\(pixels))")
}

let icns = cwd.appendingPathComponent("Resources/AppIcon.icns")
try? fm.removeItem(at: icns)
let proc = Process()
proc.launchPath = "/usr/bin/iconutil"
proc.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try proc.run()
proc.waitUntilExit()
if proc.terminationStatus != 0 { exit(proc.terminationStatus) }
print("wrote \(icns.path)")
