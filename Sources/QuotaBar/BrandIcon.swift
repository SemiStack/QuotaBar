import AppKit

enum BrandIcon {
    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            drawGlyph(in: rect.insetBy(dx: 1.6, dy: 1.6), style: .template)
            return true
        }
        image.isTemplate = true
        return image
    }()

    static let appImage: NSImage = {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { rect in
            drawAppIcon(in: rect)
            return true
        }
    }()

    @MainActor
    static func installAsApplicationIcon() {
        NSApp.applicationIconImage = appImage
    }

    private enum GlyphStyle {
        case template
        case colorful
    }

    private static func drawAppIcon(in rect: NSRect) {
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -18)
        shadow.shadowBlurRadius = 36
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.set()

        let cardRect = rect.insetBy(dx: 34, dy: 34)
        let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 108, yRadius: 108)

        let backgroundGradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.985, green: 0.989, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.93, green: 0.952, blue: 1.0, alpha: 1)
        ])
        backgroundGradient?.draw(in: cardPath, angle: -90)

        let glowRect = cardRect.insetBy(dx: 42, dy: 42)
        let glowPath = NSBezierPath(roundedRect: glowRect, xRadius: 84, yRadius: 84)
        NSColor.white.withAlphaComponent(0.62).setFill()
        glowPath.fill()

        NSColor.white.withAlphaComponent(0.78).setStroke()
        cardPath.lineWidth = 2.2
        cardPath.stroke()

        let glyphRect = NSRect(
            x: cardRect.minX + 116,
            y: cardRect.minY + 116,
            width: cardRect.width - 232,
            height: cardRect.height - 232
        )

        let glyphShadow = NSShadow()
        glyphShadow.shadowOffset = NSSize(width: 0, height: -6)
        glyphShadow.shadowBlurRadius = 14
        glyphShadow.shadowColor = NSColor(calibratedRed: 0.26, green: 0.45, blue: 1.0, alpha: 0.18)
        glyphShadow.set()

        drawGlyph(in: glyphRect, style: .colorful)
    }

    private static func drawGlyph(in rect: NSRect, style: GlyphStyle) {
        let heights: [CGFloat] = [0.34, 0.58, 0.86, 0.66, 0.44]
        let barWidth = rect.width * 0.12
        let spacing = rect.width * 0.06
        let totalBarsWidth = barWidth * CGFloat(heights.count) + spacing * CGFloat(heights.count - 1)
        let originX = rect.midX - totalBarsWidth / 2
        let baselineY = rect.minY + rect.height * 0.08

        if style == .colorful {
            let halo = NSBezierPath(ovalIn: NSRect(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.12, width: rect.width * 0.84, height: rect.height * 0.76))
            NSColor(calibratedRed: 0.42, green: 0.67, blue: 1.0, alpha: 0.08).setFill()
            halo.fill()
        }

        for (index, heightRatio) in heights.enumerated() {
            let x = originX + CGFloat(index) * (barWidth + spacing)
            let barHeight = rect.height * heightRatio
            let y = baselineY + (rect.height - barHeight) * 0.02
            let path = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: barHeight), xRadius: barWidth / 2, yRadius: barWidth / 2)

            switch style {
            case .template:
                path.fill()
            case .colorful:
                let gradient = NSGradient(colors: [
                    NSColor(calibratedRed: 0.22, green: 0.75, blue: 1.0, alpha: 1),
                    NSColor(calibratedRed: 0.29, green: 0.35, blue: 1.0, alpha: 1)
                ])
                gradient?.draw(in: path, angle: -90)
            }
        }

        let dotDiameter = barWidth * 0.82
        let dotRect = NSRect(
            x: originX - dotDiameter - spacing * 0.45,
            y: baselineY + rect.height * 0.09,
            width: dotDiameter,
            height: dotDiameter
        )
        let dotPath = NSBezierPath(ovalIn: dotRect)

        switch style {
        case .template:
            dotPath.fill()
        case .colorful:
            let dotGradient = NSGradient(colors: [
                NSColor(calibratedRed: 0.2, green: 0.84, blue: 1.0, alpha: 1),
                NSColor(calibratedRed: 0.24, green: 0.58, blue: 1.0, alpha: 1)
            ])
            dotGradient?.draw(in: dotPath, angle: -90)
        }
    }
}
