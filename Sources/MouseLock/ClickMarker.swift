import AppKit

/// A click-through overlay that briefly shows a crosshair where a click
/// landed, as feedback while the real pointer is hidden.
final class ClickMarker {
    private static let size: CGFloat = 44
    private lazy var window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = CrosshairView()
        return window
    }()

    /// `point` is in global CoreGraphics coordinates (top-left origin).
    func show(at point: CGPoint) {
        // Cocoa window coordinates have a bottom-left origin on the main screen.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = NSPoint(x: point.x, y: mainHeight - point.y)
        window.setFrameOrigin(NSPoint(x: center.x - Self.size / 2, y: center.y - Self.size / 2))
        window.alphaValue = 1
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.6
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }
    }
}

final class CrosshairView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let arm = bounds.width / 2 - 3
        let gap: CGFloat = 5
        let path = NSBezierPath()
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
            path.move(to: NSPoint(x: c.x + dx * gap, y: c.y + dy * gap))
            path.line(to: NSPoint(x: c.x + dx * arm, y: c.y + dy * arm))
        }
        path.appendOval(in: NSRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3))
        path.lineCapStyle = .round
        // White halo under black lines so it shows on any background.
        NSColor.white.setStroke()
        path.lineWidth = 4
        path.stroke()
        NSColor.black.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}
