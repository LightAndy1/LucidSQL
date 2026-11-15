#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Metrics {
    static let widthPt: CGFloat = 660
    static let heightPt: CGFloat = 420
    static let leftIconCenter = CGPoint(x: 190, y: 170)
    static let rightIconCenter = CGPoint(x: 470, y: 170)
}

func cgColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(srgbRed: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: a)
}

func makeBitmapContext(scale: CGFloat) -> CGContext? {
    let pixelW = Int(Metrics.widthPt * scale)
    let pixelH = Int(Metrics.heightPt * scale)
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    guard let ctx = CGContext(
        data: nil,
        width: pixelW,
        height: pixelH,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    // Flip into top-left point coordinates (matches Finder Iloc Y-down convention).
    ctx.translateBy(x: 0, y: CGFloat(pixelH))
    ctx.scaleBy(x: scale, y: -scale)
    return ctx
}

func drawDirectionalArrow(in ctx: CGContext) {
    let startX: CGFloat = 294
    let endX: CGFloat = 366
    let midY: CGFloat = Metrics.leftIconCenter.y
    let headLen: CGFloat = 10
    let headHalfH: CGFloat = 7.5

    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(2.2)

    // Subtle soft glow beneath arrow.
    ctx.setShadow(
        offset: CGSize(width: 0, height: 1),
        blur: 6,
        color: cgColor(14, 128, 212, 0.16)
    )

    // Tapered gradient shaft.
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let arrowPath = CGMutablePath()
    arrowPath.move(to: CGPoint(x: startX, y: midY))
    arrowPath.addLine(to: CGPoint(x: endX - 1.5, y: midY))
    arrowPath.move(to: CGPoint(x: endX - headLen, y: midY - headHalfH))
    arrowPath.addLine(to: CGPoint(x: endX, y: midY))
    arrowPath.addLine(to: CGPoint(x: endX - headLen, y: midY + headHalfH))

    ctx.addPath(arrowPath)
    ctx.replacePathWithStrokedPath()
    ctx.clip()

    let grad = CGGradient(
        colorsSpace: cs,
        colors: [
            cgColor(56, 152, 224, 0.38),
            cgColor(16, 114, 200, 0.85)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        grad,
        start: CGPoint(x: startX, y: midY),
        end: CGPoint(x: endX, y: midY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()
}

func drawInstructionText(in ctx: CGContext) {
    let text = "Drag LucidSQL to Applications."
    let font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
    let color = NSColor(srgbRed: 16/255, green: 42/255, blue: 76/255, alpha: 0.78)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .kern: 0.15
    ]
    let attrStr = NSAttributedString(string: text, attributes: attrs)
    let size = attrStr.size()
    let x = (Metrics.widthPt - size.width) / 2.0
    let y: CGFloat = 344

    // NSString drawing expects flipped or native AppKit graphics context.
    ctx.saveGState()
    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    attrStr.draw(at: CGPoint(x: x, y: y))
    NSGraphicsContext.restoreGraphicsState()
    ctx.restoreGState()
}

func renderBackground(scale: CGFloat, outputURL: URL) throws {
    guard let ctx = makeBitmapContext(scale: scale) else {
        throw NSError(domain: "DMGBg", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed bitmap context"])
    }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let bounds = CGRect(x: 0, y: 0, width: Metrics.widthPt, height: Metrics.heightPt)

    // 1. Base cool sapphire-tinted white gradient (high contrast for dark Finder icon labels).
    let baseGrad = CGGradient(
        colorsSpace: cs,
        colors: [
            cgColor(246, 250, 255, 1.0),
            cgColor(236, 245, 254, 1.0),
            cgColor(225, 238, 252, 1.0)
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    ctx.drawLinearGradient(
        baseGrad,
        start: CGPoint(x: 0, y: 0),
        end: CGPoint(x: 0, y: Metrics.heightPt),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // 2. Soft ambient cyan/azure glass bloom (startRadius: 0 prevents unfilled inner disc).
    let topGlow = CGGradient(
        colorsSpace: cs,
        colors: [
            cgColor(92, 192, 248, 0.20),
            cgColor(125, 210, 252, 0.09),
            cgColor(125, 210, 252, 0.0)
        ] as CFArray,
        locations: [0.0, 0.45, 1.0]
    )!
    ctx.drawRadialGradient(
        topGlow,
        startCenter: CGPoint(x: 210, y: 120),
        startRadius: 0,
        endCenter: CGPoint(x: 210, y: 120),
        endRadius: 340,
        options: [.drawsBeforeStartLocation]
    )

    let rightGlow = CGGradient(
        colorsSpace: cs,
        colors: [
            cgColor(56, 146, 232, 0.13),
            cgColor(56, 146, 232, 0.0)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawRadialGradient(
        rightGlow,
        startCenter: CGPoint(x: 500, y: 240),
        startRadius: 0,
        endCenter: CGPoint(x: 500, y: 240),
        endRadius: 290,
        options: [.drawsBeforeStartLocation]
    )

    // Subtle hairline top sheen.
    ctx.saveGState()
    ctx.setFillColor(cgColor(255, 255, 255, 0.75))
    ctx.fill(CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1.0))
    ctx.restoreGState()

    // 3. Restrained directional arrow (no decorative card borders near filenames).
    drawDirectionalArrow(in: ctx)

    // 4. Single concise instruction line.
    drawInstructionText(in: ctx)

    guard let image = ctx.makeImage() else {
        throw NSError(domain: "DMGBg", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage"])
    }
    guard let dest = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw NSError(domain: "DMGBg", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed image destination"])
    }
    let dpi = 72.0 * scale
    let props: [CFString: Any] = [
        kCGImagePropertyDPIWidth: dpi,
        kCGImagePropertyDPIHeight: dpi
    ]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "DMGBg", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed writing PNG"])
    }
}

let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Assets/DMG")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let out1x = outDir.appendingPathComponent("dmg-background.png")
let out2x = outDir.appendingPathComponent("dmg-background@2x.png")
try renderBackground(scale: 1.0, outputURL: out1x)
try renderBackground(scale: 2.0, outputURL: out2x)
print("Generated \(out1x.path) (660x420 @72dpi) and \(out2x.path) (1320x840 @144dpi)")
