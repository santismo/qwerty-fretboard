import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let output = resources.appendingPathComponent("AppIcon.icns")

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(String, Int, CGFloat)] = [
    ("icon_16x16.png", 16, 16),
    ("icon_16x16@2x.png", 32, 16),
    ("icon_32x32.png", 32, 32),
    ("icon_32x32@2x.png", 64, 32),
    ("icon_128x128.png", 128, 128),
    ("icon_128x128@2x.png", 256, 128),
    ("icon_256x256.png", 256, 256),
    ("icon_256x256@2x.png", 512, 256),
    ("icon_512x512.png", 512, 512),
    ("icon_512x512@2x.png", 1024, 512)
]

for (name, pixels, points) in sizes {
    let image = NSImage(size: NSSize(width: points, height: points))
    image.lockFocus()
    drawIcon(in: NSRect(x: 0, y: 0, width: points, height: points))
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [.compressionFactor: 1.0]) else {
        fatalError("Could not render \(name)")
    }
    try data.write(to: iconset.appendingPathComponent(name))
    _ = pixels
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    fatalError("iconutil failed")
}

func drawIcon(in rect: NSRect) {
    let bg = NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08), xRadius: rect.width * 0.18, yRadius: rect.height * 0.18)
    NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.10, alpha: 1).setFill()
    bg.fill()

    let board = rect.insetBy(dx: rect.width * 0.17, dy: rect.height * 0.28)
    let body = NSBezierPath(roundedRect: board, xRadius: rect.width * 0.06, yRadius: rect.width * 0.06)
    NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.98, alpha: 1).setFill()
    body.fill()

    NSColor(calibratedRed: 0.21, green: 0.23, blue: 0.25, alpha: 1).setFill()
    let keyW = board.width / 7.6
    let keyH = board.height / 5.2
    for row in 0..<3 {
        let columns = row == 2 ? 5 : 6
        let offset = row == 1 ? keyW * 0.35 : (row == 2 ? keyW * 0.9 : 0)
        for col in 0..<columns {
            let x = board.minX + keyW * 0.55 + offset + CGFloat(col) * (keyW * 1.12)
            let y = board.maxY - keyH * 1.45 - CGFloat(row) * (keyH * 1.18)
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: keyW * 0.72, height: keyH * 0.72), xRadius: keyW * 0.12, yRadius: keyW * 0.12).fill()
        }
    }

    NSColor(calibratedRed: 0.20, green: 0.80, blue: 0.45, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: board.midX - board.width * 0.23, y: board.minY + board.height * 0.13, width: board.width * 0.46, height: keyH * 0.62), xRadius: keyW * 0.14, yRadius: keyW * 0.14).fill()
}
