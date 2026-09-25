// Renders the ClaudexBar app icon (a dark tile with a notch "island" holding a glowing
// traffic light) into Support/AppIcon.icns (macOS) and the Windows .ico.
// Usage: swift Scripts/make-icons.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // Tile (macOS icon grid: ~10% margin), dark vertical gradient.
    let inset = s * 0.098
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    shadow.set()
    NSGradient(colors: [color(0x2C2C31), color(0x0C0C0E)])!.draw(in: tilePath, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    color(0xFFFFFF, 0.08).setStroke()
    tilePath.lineWidth = max(1, s * 0.004)
    tilePath.stroke()

    // The island hanging from the top edge of the tile; it holds the traffic light.
    let islandW = tile.width * 0.80, islandH = tile.height * 0.40
    let island = CGRect(x: tile.midX - islandW / 2, y: tile.maxY - islandH, width: islandW, height: islandH)
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    let islandPath = NSBezierPath()
    let r = islandH * 0.46
    islandPath.move(to: NSPoint(x: island.minX, y: island.maxY + 1))
    islandPath.line(to: NSPoint(x: island.minX, y: island.minY + r))
    islandPath.appendArc(withCenter: NSPoint(x: island.minX + r, y: island.minY + r), radius: r, startAngle: 180, endAngle: 270)
    islandPath.line(to: NSPoint(x: island.maxX - r, y: island.minY))
    islandPath.appendArc(withCenter: NSPoint(x: island.maxX - r, y: island.minY + r), radius: r, startAngle: 270, endAngle: 360)
    islandPath.line(to: NSPoint(x: island.maxX, y: island.maxY + 1))
    islandPath.close()
    let islandShadow = NSShadow()
    islandShadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    islandShadow.shadowBlurRadius = s * 0.03
    islandShadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    islandShadow.set()
    NSColor.black.setFill()
    islandPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Three glowing lamps inside the island.
    let lamp = tile.width * 0.145, gap = tile.width * 0.06
    let rowW = 3 * lamp + 2 * gap
    let lampY = island.minY + (islandH - lamp) / 2 - islandH * 0.04
    let lamps: [UInt32] = [0xFF453A, 0xFFD60A, 0x30D158]
    for (i, hex) in lamps.enumerated() {
        let c = color(hex)
        let rect = CGRect(x: tile.midX - rowW / 2 + CGFloat(i) * (lamp + gap), y: lampY, width: lamp, height: lamp)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = c.withAlphaComponent(0.95)
        glow.shadowBlurRadius = lamp * 0.6
        glow.set()
        c.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSGraphicsContext.restoreGraphicsState()
        let highlight = NSGradient(colors: [c.blended(withFraction: 0.5, of: .white)!, c])!
        highlight.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: NSPoint(x: -0.3, y: 0.35))
    }

    // A subtle usage bar below the island.
    let barW = tile.width * 0.56, barH = tile.width * 0.05
    let bar = CGRect(x: tile.midX - barW / 2, y: tile.minY + tile.height * 0.24, width: barW, height: barH)
    color(0xFFFFFF, 0.12).setFill()
    NSBezierPath(roundedRect: bar, xRadius: barH / 2, yRadius: barH / 2).fill()
    let fill = CGRect(x: bar.minX, y: bar.minY, width: barW * 0.62, height: barH)
    NSGradient(colors: [color(0x30D158), color(0xFFD60A)])!.draw(in: NSBezierPath(roundedRect: fill, xRadius: barH / 2, yRadius: barH / 2), angle: 0)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// macOS .icns via iconutil
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let icns = root.appendingPathComponent("Support/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
print("wrote \(icns.path)")

// Windows .ico (PNG-compressed entries)
let sizes = [16, 24, 32, 48, 64, 128, 256]
let images = sizes.map { render($0) }
var ico = Data()
func le16(_ v: Int) { var x = UInt16(v).littleEndian; ico.append(Data(bytes: &x, count: 2)) }
func le32(_ v: Int) { var x = UInt32(v).littleEndian; ico.append(Data(bytes: &x, count: 4)) }
le16(0); le16(1); le16(sizes.count)
var offset = 6 + 16 * sizes.count
for (size, png) in zip(sizes, images) {
    ico.append(UInt8(size == 256 ? 0 : size)); ico.append(UInt8(size == 256 ? 0 : size))
    ico.append(0); ico.append(0)
    le16(1); le16(32); le32(png.count); le32(offset)
    offset += png.count
}
for png in images { ico.append(png) }
let icoURL = root.appendingPathComponent("windows/src/ClaudexBar.App/Assets/ClaudexBar.ico")
try ico.write(to: icoURL)
try render(512).write(to: root.appendingPathComponent("Support/AppIcon-512.png"))
print("wrote \(icoURL.path)")
