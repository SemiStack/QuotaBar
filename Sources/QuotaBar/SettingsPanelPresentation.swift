import AppKit

enum SettingsWindowPlacement {
    static func frame(
        windowSize: NSSize,
        anchorFrame: NSRect?,
        visibleFrame: NSRect
    ) -> NSRect {
        let fittedSize = NSSize(
            width: min(windowSize.width, visibleFrame.width),
            height: min(windowSize.height, visibleFrame.height)
        )

        let originX = max(
            visibleFrame.minX,
            min(visibleFrame.midX - fittedSize.width / 2, visibleFrame.maxX - fittedSize.width)
        )
        let originY = max(
            visibleFrame.minY,
            min(visibleFrame.midY - fittedSize.height / 2, visibleFrame.maxY - fittedSize.height)
        )

        return NSRect(origin: NSPoint(x: originX, y: originY), size: fittedSize)
    }

    static func visibleFrame(for anchorFrame: NSRect?) -> NSRect? {
        if let anchorFrame {
            let anchorPoint = NSPoint(x: anchorFrame.midX, y: anchorFrame.midY)

            if let exactScreen = NSScreen.screens.first(where: { $0.frame.contains(anchorPoint) }) {
                return exactScreen.visibleFrame
            }

            if let intersectingScreen = NSScreen.screens.max(by: { lhs, rhs in
                lhs.frame.intersection(anchorFrame).area < rhs.frame.intersection(anchorFrame).area
            }), intersectingScreen.frame.intersects(anchorFrame) {
                return intersectingScreen.visibleFrame
            }
        }

        return NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
    }
}

private extension NSRect {
    var area: CGFloat {
        width * height
    }
}
