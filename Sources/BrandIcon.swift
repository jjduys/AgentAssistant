import AppKit

/// Shared vector mark: an assistant face inside a conversation bubble, with a spark.
@MainActor
enum BrandIcon {
    static func statusIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            drawMark(in: rect, body: .black, eyes: nil, spark: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "AgentAssistant 智能体助手"
        return image
    }

    static func drawMark(in rect: NSRect, body: NSColor, eyes: NSColor?, spark: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / 22, yBy: rect.height / 22)
        transform.concat()
        body.setFill()
        let bubble = NSBezierPath(roundedRect: NSRect(x: 2, y: 5, width: 16, height: 12), xRadius: 4.2, yRadius: 4.2)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 5.6, y: 6))
        tail.line(to: NSPoint(x: 5.2, y: 2.6))
        tail.curve(to: NSPoint(x: 10.1, y: 6), controlPoint1: NSPoint(x: 7.4, y: 3.6), controlPoint2: NSPoint(x: 9.1, y: 5.2))
        tail.close(); bubble.append(tail); bubble.fill()
        NSGraphicsContext.saveGraphicsState()
        if let eyes { eyes.setFill() } else { NSGraphicsContext.current?.cgContext.setBlendMode(.clear) }
        for x: CGFloat in [6.2, 11.6] {
            NSBezierPath(roundedRect: NSRect(x: x, y: 9.1, width: 2.2, height: 3.7), xRadius: 1.1, yRadius: 1.1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        spark.setFill()
        let star = NSBezierPath()
        let x: CGFloat = 18.5, y: CGFloat = 18.5, r: CGFloat = 3
        star.move(to: NSPoint(x: x, y: y + r))
        star.curve(to: NSPoint(x: x + r, y: y), controlPoint1: NSPoint(x: x + 0.3, y: y + 0.7), controlPoint2: NSPoint(x: x + 0.7, y: y + 0.3))
        star.curve(to: NSPoint(x: x, y: y - r), controlPoint1: NSPoint(x: x + 0.7, y: y - 0.3), controlPoint2: NSPoint(x: x + 0.3, y: y - 0.7))
        star.curve(to: NSPoint(x: x - r, y: y), controlPoint1: NSPoint(x: x - 0.3, y: y - 0.7), controlPoint2: NSPoint(x: x - 0.7, y: y - 0.3))
        star.curve(to: NSPoint(x: x, y: y + r), controlPoint1: NSPoint(x: x - 0.7, y: y + 0.3), controlPoint2: NSPoint(x: x - 0.3, y: y + 0.7))
        star.close(); star.fill()
    }

    static func appIcon(size: Int) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(size) / 1024); transform.concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 84, y: 84, width: 856, height: 856), xRadius: 194, yRadius: 194)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.3, alpha: 0.24)
        shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -12)
        if size >= 64 { shadow.set() }
        NSColor(calibratedRed: 0.19, green: 0.2, blue: 0.62, alpha: 1).setFill(); tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.21, blue: 0.57, alpha: 1),
                            NSColor(calibratedRed: 0.3, green: 0.31, blue: 0.84, alpha: 1),
                            NSColor(calibratedRed: 0.38, green: 0.54, blue: 0.97, alpha: 1)])!.draw(in: tile, angle: 65)
        NSGraphicsContext.saveGraphicsState(); tile.addClip()
        NSColor.white.withAlphaComponent(0.06).setFill()
        NSBezierPath(ovalIn: NSRect(x: 170, y: 450, width: 880, height: 650)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let outline = NSBezierPath(roundedRect: NSRect(x: 85, y: 85, width: 854, height: 854), xRadius: 193, yRadius: 193)
        NSColor.white.withAlphaComponent(0.23).setStroke(); outline.lineWidth = 2; outline.stroke()
        NSGraphicsContext.saveGraphicsState()
        let faceShadow = NSShadow(); faceShadow.shadowColor = NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.34, alpha: 0.3)
        faceShadow.shadowBlurRadius = 24; faceShadow.shadowOffset = NSSize(width: 0, height: -16); faceShadow.set()
        drawMark(in: NSRect(x: 190, y: 170, width: 660, height: 660),
                 body: NSColor(calibratedRed: 0.97, green: 0.99, blue: 1, alpha: 1),
                 eyes: NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.53, alpha: 1),
                 spark: NSColor(calibratedRed: 0.52, green: 0.97, blue: 0.92, alpha: 1))
        NSGraphicsContext.restoreGraphicsState()
        context.flushGraphics()
        return bitmap
    }
}
