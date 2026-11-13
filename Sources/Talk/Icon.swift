import AppKit

/// Talk's mark: a speech bubble with a voice wave cut out of it. Drawn in code so the menu-bar icon
/// and the app icon stay identical and sharp at every size.
enum Icon {
    enum Inner { case wave, dots }

    /// Draws the bubble filling `r` (y up), with `inner` cut out (transparent).
    static func drawGlyph(in r: NSRect, color: NSColor, inner: Inner) {
        let s = r.width / 18  // designed on an 18 x 18 grid
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + x * s, y: r.minY + y * s) }

        color.setFill()
        let body = NSBezierPath(roundedRect: NSRect(origin: p(1, 4), size: NSSize(width: 16 * s, height: 12.5 * s)),
                                xRadius: 4.5 * s, yRadius: 4.5 * s)
        body.fill()
        let tail = NSBezierPath()
        tail.move(to: p(4, 5.5))
        tail.line(to: p(3.2, 1.2))
        tail.line(to: p(9, 5.5))
        tail.close()
        tail.fill()

        let ctx = NSGraphicsContext.current
        let previous = ctx?.compositingOperation ?? .sourceOver
        ctx?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        let mid: CGFloat = 10.25
        switch inner {
        case .wave:
            let bars: [(x: CGFloat, h: CGFloat)] = [(4.6, 3.6), (7.6, 7.0), (10.6, 5.0), (13.6, 2.6)]
            for b in bars {
                let w: CGFloat = 1.8
                let rect = NSRect(origin: p(b.x - w / 2 + 0.0, mid - b.h / 2), size: NSSize(width: w * s, height: b.h * s))
                NSBezierPath(roundedRect: rect, xRadius: w / 2 * s, yRadius: w / 2 * s).fill()
            }
        case .dots:
            for x: CGFloat in [5.5, 9, 12.5] {
                let d: CGFloat = 2.2
                NSBezierPath(ovalIn: NSRect(origin: p(x - d / 2, mid - d / 2), size: NSSize(width: d * s, height: d * s))).fill()
            }
        }
        ctx?.compositingOperation = previous
    }

    /// 18 pt menu-bar image. A template (follows light/dark menu bar) unless `tint` is given.
    static func menuBar(_ inner: Inner, tint: NSColor? = nil) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            drawGlyph(in: rect, color: tint ?? .black, inner: inner)
            return true
        }
        img.isTemplate = tint == nil
        img.accessibilityDescription = "Talk"
        return img
    }

    /// The app icon (Finder, System Settings), drawn into a `px`-pixel square.
    static func drawAppIcon(px: CGFloat) {
        let canvas = NSRect(x: 0, y: 0, width: px, height: px)
        NSColor.clear.setFill()
        canvas.fill()
        // macOS icon grid: 824/1024 rounded square with a soft drop shadow.
        let k = px / 1024
        let tile = NSRect(x: 100 * k, y: 100 * k + 6 * k, width: 824 * k, height: 824 * k)
        let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * k, yRadius: 185 * k)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 20 * k
        shadow.shadowOffset = NSSize(width: 0, height: -8 * k)
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [NSColor(srgbRed: 0.42, green: 0.30, blue: 0.98, alpha: 1),
                            NSColor(srgbRed: 0.98, green: 0.36, blue: 0.55, alpha: 1)])?
            .draw(in: shape, angle: -55)

        // The white bubble goes on its own layer so its cut-outs show the gradient, not the backdrop.
        let side = 560 * k
        let glyph = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            drawGlyph(in: rect, color: .white, inner: .wave)
            return true
        }
        glyph.draw(in: NSRect(x: tile.midX - side / 2, y: tile.midY - side / 2 - 10 * k, width: side, height: side))
    }

    static func png(px: Int, draw: (CGFloat) -> Void) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(CGFloat(px))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// `Talk --render-icons <dir>`: writes <dir>/AppIcon.iconset (for iconutil) and menu-bar previews.
    static func render(to dir: URL) throws {
        let set = dir.appendingPathComponent("AppIcon.iconset")
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try png(px: base * scale, draw: drawAppIcon)?.write(to: set.appendingPathComponent(name))
            }
        }
        let states: [(String, Inner, NSColor)] = [("idle", .wave, .black), ("recording", .wave, .systemRed),
                                                  ("transcribing", .dots, .black)]
        for (name, inner, color) in states {
            try png(px: 72) { px in drawGlyph(in: NSRect(x: 0, y: 0, width: px, height: px), color: color, inner: inner) }?
                .write(to: dir.appendingPathComponent("menubar-\(name).png"))
        }
    }
}
