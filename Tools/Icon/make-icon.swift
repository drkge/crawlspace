#!/usr/bin/env swift
import AppKit

// Draws the Crawlspace icons and writes them as .icns files.
//
//   swift Tools/Icon/make-icon.swift
//
// Two things about macOS 26 shape what this produces:
//
//  - The app icon is drawn full bleed. The system masks app icons into its own rounded shape and
//    draws their shadow, so rounded corners or an inset here would show up as a second, smaller
//    icon inside the mask. Document icons are not masked, so that one draws its own page.
//  - Both are built with iconutil rather than through an asset catalogue, because Xcode 26's
//    actool writes only four of the ten sizes into the .icns it compiles (16, 32, 128 and 256)
//    and macOS draws a placeholder at the sizes that are missing — 64pt among them.

let master = 1_024.0
let space = CGColorSpaceCreateDeviceRGB()

func rgb(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

let deepBlue = rgb(0.09, 0.24, 0.72)
let markBlue = rgb(0.13, 0.33, 0.88)

/// The mark both icons share: a page that links to two more, which is the same shape as the
/// point.3.filled.connected.trianglepath.dotted symbol the app uses on screen.
///
/// Everything is proportional to `width` so the mark can be dropped into either icon.
func drawMark(in ctx: CGContext, centre: CGPoint, width w: CGFloat, ink: CGColor, behind: CGColor) {
    // Core Graphics counts y upwards, so the root page sits at the larger y.
    let root = CGPoint(x: centre.x, y: centre.y + 0.226 * w)
    let left = CGPoint(x: centre.x - 0.245 * w, y: centre.y - 0.226 * w)
    let right = CGPoint(x: centre.x + 0.245 * w, y: centre.y - 0.226 * w)

    ctx.setLineCap(.round)
    ctx.setStrokeColor(ink.copy(alpha: 0.88) ?? ink)
    ctx.setLineWidth(0.0425 * w)
    for child in [left, right] {
        ctx.move(to: root)
        ctx.addLine(to: child)
    }
    ctx.strokePath()

    // The dotted link between the two pages: the crawler following a link sideways.
    ctx.setStrokeColor(ink.copy(alpha: 0.62) ?? ink)
    ctx.setLineWidth(0.0325 * w)
    ctx.setLineDash(phase: 0, lengths: [0.0025 * w, 0.0775 * w])
    ctx.move(to: left)
    ctx.addLine(to: right)
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    func node(_ point: CGPoint, radius: CGFloat) {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        // A hairline of the background keeps each node clear of the lines running behind it.
        ctx.setFillColor(behind)
        ctx.fillEllipse(in: rect.insetBy(dx: -0.015 * w, dy: -0.015 * w))
        ctx.setFillColor(ink)
        ctx.fillEllipse(in: rect)
    }
    node(left, radius: 0.105 * w)
    node(right, radius: 0.105 * w)
    node(root, radius: 0.14 * w)
}

func drawAppIcon(in ctx: CGContext) {
    let gradient = CGGradient(colorsSpace: space, colors: [
        rgb(0.40, 0.62, 1.00), rgb(0.15, 0.35, 0.92), rgb(0.05, 0.17, 0.62),
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: master),
                           end: CGPoint(x: master, y: 0), options: [])

    // A soft highlight behind the root node, so the mark sits on the background rather than
    // looking pasted onto it.
    let glow = CGGradient(colorsSpace: space, colors: [
        rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 694), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 694), endRadius: 430, options: [])

    drawMark(in: ctx, centre: CGPoint(x: 512, y: 513), width: 800, ink: rgb(1, 1, 1), behind: deepBlue)
}

/// A .crawlspace package: a page with one corner turned down, carrying the mark.
func drawDocumentIcon(in ctx: CGContext) {
    let page = CGRect(x: 196, y: 84, width: 632, height: 856)
    let fold: CGFloat = 176
    let radius: CGFloat = 26

    // Corners, clockwise from the bottom left, with the top right cut away for the fold.
    let path = CGMutablePath()
    path.move(to: CGPoint(x: page.minX, y: page.minY + radius))
    path.addArc(tangent1End: CGPoint(x: page.minX, y: page.maxY),
                tangent2End: CGPoint(x: page.minX + radius, y: page.maxY), radius: radius)
    path.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    path.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    path.addArc(tangent1End: CGPoint(x: page.maxX, y: page.minY),
                tangent2End: CGPoint(x: page.maxX - radius, y: page.minY), radius: radius)
    path.addArc(tangent1End: CGPoint(x: page.minX, y: page.minY),
                tangent2End: CGPoint(x: page.minX, y: page.minY + radius), radius: radius)
    path.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: rgb(0.10, 0.14, 0.26, 0.28))
    ctx.setFillColor(rgb(1, 1, 1))
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()

    // The turned-down corner, drawn as if the back of the sheet is showing.
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    flap.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    flap.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
    flap.closeSubpath()
    ctx.saveGState()
    ctx.addPath(flap)
    ctx.clip()
    let shade = CGGradient(colorsSpace: space, colors: [
        rgb(0.84, 0.87, 0.92), rgb(0.94, 0.96, 0.98),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shade, start: CGPoint(x: page.maxX - fold, y: page.maxY),
                           end: CGPoint(x: page.maxX, y: page.maxY - fold), options: [])
    ctx.restoreGState()

    ctx.setStrokeColor(rgb(0.78, 0.81, 0.86))
    ctx.setLineWidth(4)
    ctx.addPath(path)
    ctx.addPath(flap)
    ctx.strokePath()

    drawMark(in: ctx, centre: CGPoint(x: page.midX, y: page.midY + 24), width: 420,
             ink: markBlue, behind: rgb(1, 1, 1))
}

func png(size: CGFloat, draw: (CGContext) -> Void) -> Data {
    let pixels = Int(size)
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.scaleBy(x: size / master, y: size / master)
    draw(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

/// The sizes an .iconset has to contain, as point size and scale.
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                              (256, 1), (256, 2), (512, 1), (512, 2)]

func writeICNS(named name: String, draw: (CGContext) -> Void) throws {
    let iconset = FileManager.default.temporaryDirectory
        .appending(path: "\(name)-\(UUID().uuidString).iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: iconset) }

    for (points, scale) in variants {
        let file = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(size: CGFloat(points * scale), draw: draw).write(to: iconset.appending(path: file))
    }

    let root = URL(filePath: FileManager.default.currentDirectoryPath)
    let destination = root.appending(path: "Tools/Release/Resources/\(name).icns")
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let iconutil = Process()
    iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
    iconutil.arguments = ["--convert", "icns", iconset.path, "--output", destination.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        FileHandle.standardError.write(Data("iconutil failed for \(name)\n".utf8))
        exit(1)
    }
    let kilobytes = (try Data(contentsOf: destination)).count / 1_024
    print("\(destination.path)  \(kilobytes) KB, \(variants.count) sizes")
}

try writeICNS(named: "AppIcon", draw: drawAppIcon)
try writeICNS(named: "CrawlDocument", draw: drawDocumentIcon)
