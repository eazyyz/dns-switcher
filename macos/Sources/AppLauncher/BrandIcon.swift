import AppKit

enum BrandIcon {
    /// Small-size vector adaptation of Resources/BrandLogo.png, independent of raster resolution.
    /// Template rendering follows the menu bar theme.
    static let menuBar: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }

            let letter = NSBezierPath()
            letter.move(to: NSPoint(x: 3, y: 2))
            letter.line(to: NSPoint(x: 3, y: 16))
            letter.line(to: NSPoint(x: 8.5, y: 16))
            letter.curve(to: NSPoint(x: 15, y: 10), controlPoint1: NSPoint(x: 12.5, y: 16), controlPoint2: NSPoint(x: 15, y: 14))
            letter.line(to: NSPoint(x: 15, y: 8))
            letter.curve(to: NSPoint(x: 8.5, y: 2), controlPoint1: NSPoint(x: 15, y: 4), controlPoint2: NSPoint(x: 12.5, y: 2))
            letter.close()
            letter.move(to: NSPoint(x: 6, y: 5))
            letter.line(to: NSPoint(x: 8.5, y: 5))
            letter.curve(to: NSPoint(x: 12, y: 8.5), controlPoint1: NSPoint(x: 11, y: 5), controlPoint2: NSPoint(x: 12, y: 6))
            letter.line(to: NSPoint(x: 12, y: 9.5))
            letter.curve(to: NSPoint(x: 8.5, y: 13), controlPoint1: NSPoint(x: 12, y: 12), controlPoint2: NSPoint(x: 11, y: 13))
            letter.line(to: NSPoint(x: 6, y: 13))
            letter.close()
            letter.windingRule = .evenOdd
            NSColor.black.setFill()
            letter.fill()

            let bolt = NSBezierPath()
            bolt.move(to: NSPoint(x: 12.5, y: 17))
            bolt.line(to: NSPoint(x: 5.5, y: 8))
            bolt.line(to: NSPoint(x: 8.5, y: 8))
            bolt.line(to: NSPoint(x: 5.5, y: 1))
            bolt.line(to: NSPoint(x: 13, y: 10.5))
            bolt.line(to: NSPoint(x: 10, y: 10.5))
            bolt.close()
            // A transparent gap keeps the bolt distinct from the letter at 18 points.
            bolt.lineWidth = 1.2
            bolt.lineJoinStyle = .round
            NSGraphicsContext.current?.compositingOperation = .clear
            bolt.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            bolt.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "DNS Switcher"
        return image
    }()
}
