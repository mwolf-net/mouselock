import AppKit

/// Match Screen Edges: when the pointer crosses between two screens side by
/// side, it lands at the same fraction of the height on the other screen, as
/// if their physical corners touched. Without it macOS keeps the pointer at
/// the same height in points, which with a Retina screen next to a lower
/// resolution one of about the same size feels off (and along part of the
/// edge, it can't cross at all).
final class EdgeMatcher {
    var enabled = false {
        didSet { updateTap() }
    }
    /// A screen to leave alone (the touch screen, which the mouse is kept off
    /// in smart touch mode).
    var excluded: CGDirectDisplayID?
    var isTouchEvent: ((CGEvent) -> Bool)?

    private var tap: CFMachPort?
    /// The screens' bounds, kept rather than looked up on every move.
    private var screens: [CGRect] = []
    /// Where the pointer was after the last event, so a push against an edge
    /// that macOS stopped is still seen as crossing it.
    private var last: CGPoint?

    /// Called when the display configuration changes.
    func refresh() {
        screens = Display.all().map { CGDisplayBounds($0.id) }
        last = nil
    }

    private func updateTap() {
        refresh()
        if !enabled {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            return
        }
        guard let tap = ensureTap() else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func ensureTap() -> CFMachPort? {
        if let tap { return tap }
        guard AXIsProcessTrusted() else { return nil }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let matcher = Unmanaged<EdgeMatcher>.fromOpaque(refcon!).takeUnretainedValue()
            return matcher.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        return tap
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if enabled, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        let now = event.location
        defer { last = event.location }
        guard enabled, !(isTouchEvent?(event) ?? false) else { return pass }

        let delta = CGPoint(x: event.getDoubleValueField(.mouseEventDeltaX),
                            y: event.getDoubleValueField(.mouseEventDeltaY))
        // Where the pointer came from: the last position, unless something
        // else moved it since (a warp, a touch), then work back from here.
        var from = CGPoint(x: now.x - delta.x, y: now.y - delta.y)
        if let last, hypot(now.x - last.x, now.y - last.y) <= hypot(delta.x, delta.y) + 2 {
            from = last
        }
        guard let source = screens.first(where: { $0.contains(from) }) else { return pass }
        let to = CGPoint(x: from.x + delta.x, y: from.y + delta.y)
        let goingRight = to.x >= source.maxX
        guard goingRight || to.x < source.minX else { return pass }

        // The one screen on that side, sharing part of the edge.
        let edge = goingRight ? source.maxX : source.minX
        let neighbours = screens.filter { screen in
            abs((goingRight ? screen.minX : screen.maxX) - edge) < 1
                && screen.minY < source.maxY && screen.maxY > source.minY
        }
        guard neighbours.count == 1, let target = neighbours.first,
              excluded.map({ CGDisplayBounds($0) != target && CGDisplayBounds($0) != source }) ?? true
        else { return pass }

        let fraction = min(max((to.y - source.minY) / source.height, 0), 1)
        let overshoot = goingRight ? to.x - source.maxX : to.x - source.minX
        let mapped = CGPoint(
            x: goingRight ? min(target.minX + overshoot, target.maxX - 1)
                : max(target.maxX - 1 + overshoot, target.minX),
            y: min(target.minY + fraction * target.height, target.maxY - 1).rounded(.down)
        )
        event.location = mapped
        movePointer(to: mapped)
        return pass
    }
}
