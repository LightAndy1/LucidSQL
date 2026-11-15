#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import WebKit

struct VariantSpec {
    let label: String
    let subtitle: String
    let desktopBg: NSColor
    let tileTop: CGColor
    let tileBottom: CGColor
    let rimTop: CGColor
    let rimBottom: CGColor
    let isDarkTextOnLabel: Bool
    let isClearMode: Bool
    let isMonoOrTint: Bool
    let tintColor: (r: CGFloat, g: CGFloat, b: CGFloat)?
    let glowOpacity: CGFloat
    let layerOpacities: (bottom: CGFloat, mid: CGFloat, top: CGFloat, spec: CGFloat)
}

@MainActor
final class SvgLayerRenderer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView!
    private var continuation: CheckedContinuation<CGImage, Error>?

    override init() {
        super.init()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1024), configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
    }

    func render(svgXML: String) async throws -> CGImage {
        let html = """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          html, body { margin: 0; padding: 0; width: 1024px; height: 1024px; background: transparent; overflow: hidden; }
          svg { display: block; width: 1024px; height: 1024px; }
        </style>
        </head>
        <body>\(svgXML)</body>
        </html>
        """
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let snapCfg = WKSnapshotConfiguration()
        snapCfg.rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        snapCfg.snapshotWidth = 1024
        webView.takeSnapshot(with: snapCfg) { image, error in
            if let error {
                self.continuation?.resume(throwing: error)
                self.continuation = nil
                return
            }
            guard let image,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self.continuation?.resume(throwing: NSError(domain: "SvgLayerRenderer", code: 1))
                self.continuation = nil
                return
            }
            self.continuation?.resume(returning: cg)
            self.continuation = nil
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

func makeMonochromeSVG(_ xml: String, fillHex: String, strokeHex: String) -> String {
    // Re-color fills and strokes cleanly while preserving SVG geometry, gradients, and opacity structure.
    var out = xml
    let colorMap = [
        "#22D3EE": fillHex, "#67E8F9": fillHex, "#A5F3FC": fillHex, "#ECFEFF": strokeHex,
        "#0284C7": fillHex, "#0EA5E9": fillHex, "#1D4ED8": fillHex, "#38BDF8": fillHex,
        "#7DD3FC": strokeHex, "#BAE6FD": strokeHex, "#CFFAFE": strokeHex, "#E0F2FE": strokeHex,
        "#FFFFFF": strokeHex
    ]
    for (src, dst) in colorMap {
        out = out.replacingOccurrences(of: src, with: dst)
    }
    return out
}

func composeVariant(
    spec: VariantSpec,
    glowCG: CGImage,
    botCG: CGImage,
    midCG: CGImage,
    topCG: CGImage,
    specCG: CGImage,
    size: Int = 1024
) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let s = CGFloat(size) / 1024.0
    ctx.scaleBy(x: s, y: s)
    ctx.interpolationQuality = .high

    let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = RoundedRectangle(cornerRadius: 824.0 * 0.2237, style: .continuous)
        .path(in: tileRect)
        .cgPath

    // Soft macOS Dock/Finder ambient drop shadow.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -18),
        blur: 32,
        color: CGColor(red: 0, green: 0.02, blue: 0.08, alpha: spec.isClearMode ? 0.26 : 0.46)
    )
    ctx.addPath(tilePath)
    ctx.setFillColor(spec.tileBottom)
    ctx.fillPath()
    ctx.restoreGState()

    // Clipped tile interior
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    if let bgGrad = CGGradient(
        colorsSpace: cs,
        colors: [spec.tileTop, spec.tileBottom] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: tileRect.minX + 120, y: tileRect.maxY),
            end: CGPoint(x: tileRect.maxX - 120, y: tileRect.minY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    if let tint = spec.tintColor {
        ctx.setFillColor(CGColor(red: tint.r, green: tint.g, blue: tint.b, alpha: spec.isClearMode ? 0.26 : 0.36))
        ctx.fill(tileRect)
    }

    // SVG layers map inside tileRect with slight scale to balance optical density inside squircle.
    let artRect = CGRect(x: 42, y: 42, width: 940, height: 940)

    if spec.glowOpacity > 0.01 {
        ctx.saveGState()
        ctx.setAlpha(spec.glowOpacity)
        ctx.draw(glowCG, in: artRect)
        ctx.restoreGState()
    }

    // Group shadow behind cylinder stack
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -12),
        blur: 22,
        color: CGColor(red: 0, green: 0.02, blue: 0.08, alpha: spec.isClearMode ? 0.22 : 0.35)
    )
    ctx.setAlpha(spec.layerOpacities.bottom)
    ctx.draw(botCG, in: artRect)
    ctx.setAlpha(spec.layerOpacities.mid)
    ctx.draw(midCG, in: artRect)
    ctx.setAlpha(spec.layerOpacities.top)
    ctx.draw(topCG, in: artRect)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setAlpha(spec.layerOpacities.spec)
    ctx.draw(specCG, in: artRect)
    ctx.restoreGState()

    // Top-lit glass inner bevel
    ctx.saveGState()
    ctx.setLineWidth(6.0)
    ctx.addPath(tilePath)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    if let rimGrad = CGGradient(
        colorsSpace: cs,
        colors: [spec.rimTop, spec.rimBottom] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.drawLinearGradient(
            rimGrad,
            start: CGPoint(x: 512, y: tileRect.maxY),
            end: CGPoint(x: 512, y: tileRect.minY),
            options: []
        )
    }
    ctx.restoreGState()
    ctx.restoreGState()

    // Crisp outer hairline
    ctx.saveGState()
    ctx.setLineWidth(1.5)
    ctx.addPath(tilePath)
    ctx.setStrokeColor(CGColor(red: 0.05, green: 0.14, blue: 0.28, alpha: spec.isClearMode ? 0.24 : 0.34))
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

@MainActor
func renderCompositeSVG(_ xmls: [String], renderer: SvgLayerRenderer) async throws -> CGImage {
    let images = try await withThrowingTaskGroup(of: (Int, CGImage).self) { _ in
        var rendered: [CGImage] = []
        rendered.reserveCapacity(xmls.count)
        for xml in xmls {
            rendered.append(try await renderer.render(svgXML: xml))
        }
        return rendered
    }
    if images.count == 1 {
        return images[0]
    }
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: 1024,
        height: 1024,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let fullRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    for img in images {
        ctx.draw(img, in: fullRect)
    }
    return ctx.makeImage()!
}

@MainActor
func runMain() async throws {
    let args = CommandLine.arguments
    let scriptURL = URL(fileURLWithPath: args[0])
    let iconDir = scriptURL.deletingLastPathComponent()
    let assetsDir = iconDir.appendingPathComponent("LucidSQL.icon/Assets")
    let masterOut = iconDir.appendingPathComponent("LucidSQL-1024.png")

    var previewOutPath: String? = nil
    if let idx = args.firstIndex(of: "--preview-sheet"), idx + 1 < args.count {
        previewOutPath = args[idx + 1]
    }

        let glowSVG = try String(contentsOf: assetsDir.appendingPathComponent("01-ambient-glow.svg"), encoding: .utf8)
        let botSVGs = [
            try String(contentsOf: assetsDir.appendingPathComponent("02-cylinder-bottom.svg"), encoding: .utf8),
            try String(contentsOf: assetsDir.appendingPathComponent("02b-cylinder-bottom-cap.svg"), encoding: .utf8),
        ]
        let midSVGs = [
            try String(contentsOf: assetsDir.appendingPathComponent("03-cylinder-middle.svg"), encoding: .utf8),
            try String(contentsOf: assetsDir.appendingPathComponent("03b-cylinder-middle-cap.svg"), encoding: .utf8),
        ]
        let topSVGs = [
            try String(contentsOf: assetsDir.appendingPathComponent("04-cylinder-top.svg"), encoding: .utf8),
            try String(contentsOf: assetsDir.appendingPathComponent("04b-cylinder-top-cap.svg"), encoding: .utf8),
            try String(contentsOf: assetsDir.appendingPathComponent("04c-cylinder-top-dish.svg"), encoding: .utf8),
        ]
        let specSVG = try String(contentsOf: assetsDir.appendingPathComponent("05-specular-highlights.svg"), encoding: .utf8)

        let renderer = await SvgLayerRenderer()

        // Color SVG layers
        let glowCG = try await renderer.render(svgXML: glowSVG)
        let botCG = try await renderCompositeSVG(botSVGs, renderer: renderer)
        let midCG = try await renderCompositeSVG(midSVGs, renderer: renderer)
        let topCG = try await renderCompositeSVG(topSVGs, renderer: renderer)
        let specCG = try await renderer.render(svgXML: specSVG)

        let defaultSpec = VariantSpec(
            label: "Default",
            subtitle: "macOS Light Desktop",
            desktopBg: NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.98, alpha: 1.0),
            tileTop: CGColor(red: 0.067, green: 0.231, blue: 0.541, alpha: 1.0),
            tileBottom: CGColor(red: 0.016, green: 0.055, blue: 0.173, alpha: 1.0),
            rimTop: CGColor(red: 0.72, green: 0.95, blue: 1.0, alpha: 0.56),
            rimBottom: CGColor(red: 0.10, green: 0.28, blue: 0.62, alpha: 0.30),
            isDarkTextOnLabel: true,
            isClearMode: false,
            isMonoOrTint: false,
            tintColor: nil,
            glowOpacity: 0.85,
            layerOpacities: (1.0, 1.0, 1.0, 0.92)
        )

        let defaultMaster = composeVariant(
            spec: defaultSpec,
            glowCG: glowCG,
            botCG: botCG,
            midCG: midCG,
            topCG: topCG,
            specCG: specCG,
            size: 1024
        )
        let pngData = NSBitmapImageRep(cgImage: defaultMaster).representation(using: .png, properties: [:])!
        try pngData.write(to: masterOut)
        print("Wrote \(masterOut.path)")

        if let previewOutPath {
            // Render monochrome SVG layers (white/ice-silver for dark/tinted, slate-ink for clear light)
            let mBotLight = try await renderCompositeSVG(botSVGs.map { makeMonochromeSVG($0, fillHex: "#334155", strokeHex: "#0F172A") }, renderer: renderer)
            let mMidLight = try await renderCompositeSVG(midSVGs.map { makeMonochromeSVG($0, fillHex: "#475569", strokeHex: "#0F172A") }, renderer: renderer)
            let mTopLight = try await renderCompositeSVG(topSVGs.map { makeMonochromeSVG($0, fillHex: "#64748B", strokeHex: "#1E293B") }, renderer: renderer)
            let mSpecLight = try await renderer.render(svgXML: makeMonochromeSVG(specSVG, fillHex: "#0F172A", strokeHex: "#FFFFFF"))

            let mBotDark = try await renderCompositeSVG(botSVGs.map { makeMonochromeSVG($0, fillHex: "#CBD5E1", strokeHex: "#F8FAFC") }, renderer: renderer)
            let mMidDark = try await renderCompositeSVG(midSVGs.map { makeMonochromeSVG($0, fillHex: "#E2E8F0", strokeHex: "#FFFFFF") }, renderer: renderer)
            let mTopDark = try await renderCompositeSVG(topSVGs.map { makeMonochromeSVG($0, fillHex: "#F8FAFC", strokeHex: "#FFFFFF") }, renderer: renderer)
            let mSpecDark = try await renderer.render(svgXML: makeMonochromeSVG(specSVG, fillHex: "#FFFFFF", strokeHex: "#FFFFFF"))

            let variants: [(VariantSpec, Bool)] = [
                (defaultSpec, false),
                (VariantSpec(
                    label: "Dark",
                    subtitle: "macOS Dark Desktop",
                    desktopBg: NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 1.0),
                    tileTop: CGColor(red: 0.039, green: 0.125, blue: 0.329, alpha: 1.0),
                    tileBottom: CGColor(red: 0.012, green: 0.027, blue: 0.090, alpha: 1.0),
                    rimTop: CGColor(red: 0.72, green: 0.95, blue: 1.0, alpha: 0.52),
                    rimBottom: CGColor(red: 0.06, green: 0.20, blue: 0.52, alpha: 0.34),
                    isDarkTextOnLabel: false,
                    isClearMode: false,
                    isMonoOrTint: false,
                    tintColor: nil,
                    glowOpacity: 1.0,
                    layerOpacities: (1.0, 1.0, 1.0, 1.0)
                ), false),
                (VariantSpec(
                    label: "Mono",
                    subtitle: "Neutral Monochrome",
                    desktopBg: NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.18, alpha: 1.0),
                    tileTop: CGColor(red: 0.25, green: 0.28, blue: 0.32, alpha: 1.0),
                    tileBottom: CGColor(red: 0.13, green: 0.15, blue: 0.18, alpha: 1.0),
                    rimTop: CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.55),
                    rimBottom: CGColor(red: 0.3, green: 0.32, blue: 0.36, alpha: 0.35),
                    isDarkTextOnLabel: false,
                    isClearMode: false,
                    isMonoOrTint: true,
                    tintColor: nil,
                    glowOpacity: 0.0,
                    layerOpacities: (0.64, 0.80, 0.96, 1.0)
                ), true),
                (VariantSpec(
                    label: "Clear Light",
                    subtitle: "Frosted Light Glass",
                    desktopBg: NSColor(calibratedRed: 0.86, green: 0.91, blue: 0.96, alpha: 1.0),
                    tileTop: CGColor(red: 0.98, green: 0.99, blue: 1.0, alpha: 0.66),
                    tileBottom: CGColor(red: 0.84, green: 0.89, blue: 0.95, alpha: 0.54),
                    rimTop: CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.90),
                    rimBottom: CGColor(red: 0.40, green: 0.50, blue: 0.65, alpha: 0.42),
                    isDarkTextOnLabel: true,
                    isClearMode: true,
                    isMonoOrTint: true,
                    tintColor: nil,
                    glowOpacity: 0.0,
                    layerOpacities: (0.62, 0.78, 0.94, 0.95)
                ), false),
                (VariantSpec(
                    label: "Clear Dark",
                    subtitle: "Smoked Dark Glass",
                    desktopBg: NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.19, alpha: 1.0),
                    tileTop: CGColor(red: 0.24, green: 0.27, blue: 0.34, alpha: 0.62),
                    tileBottom: CGColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 0.72),
                    rimTop: CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.56),
                    rimBottom: CGColor(red: 0.15, green: 0.20, blue: 0.30, alpha: 0.35),
                    isDarkTextOnLabel: false,
                    isClearMode: true,
                    isMonoOrTint: true,
                    tintColor: nil,
                    glowOpacity: 0.0,
                    layerOpacities: (0.62, 0.78, 0.95, 1.0)
                ), true),
                (VariantSpec(
                    label: "Tinted Light (Cyan)",
                    subtitle: "System Tint: Ocean",
                    desktopBg: NSColor(calibratedRed: 0.88, green: 0.94, blue: 0.97, alpha: 1.0),
                    tileTop: CGColor(red: 0.95, green: 0.98, blue: 1.0, alpha: 0.72),
                    tileBottom: CGColor(red: 0.78, green: 0.89, blue: 0.96, alpha: 0.70),
                    rimTop: CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.88),
                    rimBottom: CGColor(red: 0.04, green: 0.45, blue: 0.75, alpha: 0.42),
                    isDarkTextOnLabel: true,
                    isClearMode: true,
                    isMonoOrTint: true,
                    tintColor: (0.04, 0.52, 0.88),
                    glowOpacity: 0.0,
                    layerOpacities: (0.64, 0.80, 0.95, 0.95)
                ), false),
                (VariantSpec(
                    label: "Tinted Dark (Coral)",
                    subtitle: "System Tint: Coral",
                    desktopBg: NSColor(calibratedRed: 0.15, green: 0.11, blue: 0.12, alpha: 1.0),
                    tileTop: CGColor(red: 0.32, green: 0.18, blue: 0.17, alpha: 0.85),
                    tileBottom: CGColor(red: 0.16, green: 0.09, blue: 0.10, alpha: 0.92),
                    rimTop: CGColor(red: 1.0, green: 0.86, blue: 0.82, alpha: 0.56),
                    rimBottom: CGColor(red: 0.40, green: 0.14, blue: 0.12, alpha: 0.36),
                    isDarkTextOnLabel: false,
                    isClearMode: true,
                    isMonoOrTint: true,
                    tintColor: (0.88, 0.32, 0.24),
                    glowOpacity: 0.0,
                    layerOpacities: (0.62, 0.80, 0.96, 1.0)
                ), true),
                (VariantSpec(
                    label: "Tinted Dark (Emerald)",
                    subtitle: "System Tint: Emerald",
                    desktopBg: NSColor(calibratedRed: 0.09, green: 0.14, blue: 0.12, alpha: 1.0),
                    tileTop: CGColor(red: 0.12, green: 0.28, blue: 0.22, alpha: 0.85),
                    tileBottom: CGColor(red: 0.06, green: 0.14, blue: 0.11, alpha: 0.92),
                    rimTop: CGColor(red: 0.80, green: 1.0, blue: 0.90, alpha: 0.56),
                    rimBottom: CGColor(red: 0.08, green: 0.32, blue: 0.20, alpha: 0.36),
                    isDarkTextOnLabel: false,
                    isClearMode: true,
                    isMonoOrTint: true,
                    tintColor: (0.10, 0.70, 0.46),
                    glowOpacity: 0.0,
                    layerOpacities: (0.62, 0.80, 0.96, 1.0)
                ), true),
            ]

            let sheetW = 1280
            let sheetH = 820
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: sheetW, pixelsHigh: sheetH,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            NSGraphicsContext.saveGraphicsState()
            let gctx = NSGraphicsContext(bitmapImageRep: rep)!
            NSGraphicsContext.current = gctx

            NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1.0).setFill()
            NSRect(x: 0, y: 0, width: sheetW, height: sheetH).fill()

            ("LucidSQL Icon Appearances — Vector/CoreGraphics Simulation Preview" as NSString).draw(
                at: NSPoint(x: 36, y: sheetH - 44),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
                    .foregroundColor: NSColor.white
                ]
            )
            ("Rendered from editable SVG layers + icon.json specs. Note: Xcode / Icon Composer (actool/ictool) not installed locally; live Assets.car compilation required for system Dark/Mono/Clear/Tinted." as NSString).draw(
                at: NSPoint(x: 36, y: sheetH - 68),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1.0)
                ]
            )

            let cardW: CGFloat = 285
            let cardH: CGFloat = 232
            let gapX: CGFloat = 22
            let gapY: CGFloat = 22
            let startX: CGFloat = 36
            let topRowY: CGFloat = CGFloat(sheetH) - 96 - cardH

            for (i, (vspec, useDarkMono)) in variants.enumerated() {
                let col = i % 4
                let row = i / 4
                let cx = startX + CGFloat(col) * (cardW + gapX)
                let cy = topRowY - CGFloat(row) * (cardH + gapY)
                let cardRect = NSRect(x: cx, y: cy, width: cardW, height: cardH)
                let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 16, yRadius: 16)
                vspec.desktopBg.setFill()
                cardPath.fill()
                NSColor(calibratedWhite: vspec.isDarkTextOnLabel ? 0.0 : 1.0, alpha: 0.12).setStroke()
                cardPath.lineWidth = 1
                cardPath.stroke()

                let iconCG: CGImage
                if vspec.isMonoOrTint {
                    iconCG = composeVariant(
                        spec: vspec,
                        glowCG: glowCG,
                        botCG: useDarkMono ? mBotDark : mBotLight,
                        midCG: useDarkMono ? mMidDark : mMidLight,
                        topCG: useDarkMono ? mTopDark : mTopLight,
                        specCG: useDarkMono ? mSpecDark : mSpecLight,
                        size: 512
                    )
                } else {
                    iconCG = composeVariant(
                        spec: vspec,
                        glowCG: glowCG,
                        botCG: botCG,
                        midCG: midCG,
                        topCG: topCG,
                        specCG: specCG,
                        size: 512
                    )
                }

                let iconNS = NSImage(cgImage: iconCG, size: NSSize(width: 152, height: 152))
                iconNS.draw(in: NSRect(x: cx + (cardW - 152) / 2, y: cy + 62, width: 152, height: 152))

                (vspec.label as NSString).draw(
                    at: NSPoint(x: cx + 16, y: cy + 34),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
                        .foregroundColor: vspec.isDarkTextOnLabel ? NSColor.black.withAlphaComponent(0.88) : NSColor.white
                    ]
                )
                (vspec.subtitle as NSString).draw(
                    at: NSPoint(x: cx + 16, y: cy + 15),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                        .foregroundColor: vspec.isDarkTextOnLabel ? NSColor.black.withAlphaComponent(0.56) : NSColor.white.withAlphaComponent(0.65)
                    ]
                )
            }

            // Bottom strip: Small-size readability check (Default icon at 128, 64, 32, 16)
            let stripRect = NSRect(x: 36, y: 24, width: CGFloat(sheetW - 72), height: 190)
            let stripPath = NSBezierPath(roundedRect: stripRect, xRadius: 16, yRadius: 16)
            NSColor(calibratedWhite: 0.94, alpha: 1.0).setFill()
            stripPath.fill()

            ("Fallback .icns Multi-Size Check (Light & Dark Surfaces)" as NSString).draw(
                at: NSPoint(x: 56, y: 184),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor.black.withAlphaComponent(0.82)
                ]
            )

            let defaultNS = NSImage(cgImage: defaultMaster, size: NSSize(width: 1024, height: 1024))
            let sizes: [CGFloat] = [128, 64, 32, 16]
            var sx: CGFloat = 60
            for sz in sizes {
                defaultNS.draw(in: NSRect(x: sx, y: 46 + (128 - sz) / 2, width: sz, height: sz))
                ("\(Int(sz))px" as NSString).draw(
                    at: NSPoint(x: sx, y: 28),
                    withAttributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium),
                        .foregroundColor: NSColor.darkGray
                    ]
                )
                sx += sz + 44
            }

            // Dark inset half on right side of bottom strip
            let darkInset = NSRect(x: 640, y: 34, width: 584, height: 170)
            NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1.0).setFill()
            NSBezierPath(roundedRect: darkInset, xRadius: 12, yRadius: 12).fill()

            var dx: CGFloat = 670
            for sz in sizes {
                defaultNS.draw(in: NSRect(x: dx, y: 54 + (128 - sz) / 2, width: sz, height: sz))
                ("\(Int(sz))px" as NSString).draw(
                    at: NSPoint(x: dx, y: 38),
                    withAttributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium),
                        .foregroundColor: NSColor.lightGray
                    ]
                )
                dx += sz + 44
            }

            NSGraphicsContext.restoreGraphicsState()
            let previewData = rep.representation(using: .png, properties: [:])!
            try previewData.write(to: URL(fileURLWithPath: previewOutPath))
            print("Wrote preview sheet to \(previewOutPath)")
        }
}

Task { @MainActor in
    do {
        try await runMain()
        exit(0)
    } catch {
        fputs("Error: \(error)\n", stderr)
        exit(1)
    }
}
app.run()
