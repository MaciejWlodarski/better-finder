import AppKit

let size = NSSize(width: 512, height: 512)
let img = NSImage(size: size)
img.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// Draw macOS Squircle Background with deep vibrant Finder blue gradient
let rect = CGRect(x: 28, y: 28, width: 456, height: 456)
let path = NSBezierPath(roundedRect: rect, xRadius: 104, yRadius: 104)
path.addClip()

let colorSpace = CGColorSpaceCreateDeviceRGB()
let colors = [
    CGColor(red: 0.08, green: 0.45, blue: 0.98, alpha: 1.0),
    CGColor(red: 0.04, green: 0.22, blue: 0.68, alpha: 1.0)
] as CFArray
if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 256, y: 484), end: CGPoint(x: 256, y: 28), options: [])
}

// Draw stylized folder + lightning fsearch bolt
let config = NSImage.SymbolConfiguration(pointSize: 210, weight: .bold)
if let folderSym = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let tinted = NSImage(size: folderSym.size)
    tinted.lockFocus()
    NSColor.white.withAlphaComponent(0.95).set()
    let symRect = NSRect(origin: .zero, size: folderSym.size)
    folderSym.draw(in: symRect)
    symRect.fill(using: .sourceIn)
    tinted.unlockFocus()

    let drawRect = NSRect(
        x: (512 - tinted.size.width) / 2,
        y: (512 - tinted.size.height) / 2 - 10,
        width: tinted.size.width,
        height: tinted.size.height
    )
    tinted.draw(in: drawRect)
}

let boltConfig = NSImage.SymbolConfiguration(pointSize: 105, weight: .black)
if let boltSym = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?.withSymbolConfiguration(boltConfig) {
    let tintedBolt = NSImage(size: boltSym.size)
    tintedBolt.lockFocus()
    NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.15, alpha: 1.0).set()
    let symRect = NSRect(origin: .zero, size: boltSym.size)
    boltSym.draw(in: symRect)
    symRect.fill(using: .sourceIn)
    tintedBolt.unlockFocus()

    let drawRect = NSRect(
        x: (512 - tintedBolt.size.width) / 2,
        y: (512 - tintedBolt.size.height) / 2 - 22,
        width: tintedBolt.size.width,
        height: tintedBolt.size.height
    )
    tintedBolt.draw(in: drawRect)
}

img.unlockFocus()

if let tiff = img.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/AppIcon.png"
    try? png.write(to: URL(fileURLWithPath: outPath))
}
