import AppKit

/// Match Screen Edges: when the pointer crosses between two screens side by
/// side, it lands at the same fraction of the height on the other screen, as
/// if their physical corners touched. Without it macOS keeps the pointer at
/// the same height in points, which with a Retina screen next to a lower
/// resolution one of about the same size feels off (and along part of the
/// edge, it can't cross at all).
///
/// Wrap Pointer Around: pushing the pointer off the outer side of the
/// rightmost screen brings it in on the leftmost one, and the other way
/// round, as if the screens were on a cylinder.
final class EdgeMatcher {
    /// Match Screen Edges.
    var enabled = false {
        didSet { updateTap() }
    }
    var wrap = false {
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
    /// Whether the current drag may wrap around: not when it started on a
    /// window's edge (a resize), where jumping across would only confuse.
    private var dragMayWrap = false

    /// Called when the display configuration changes.
    func refresh() {
        screens = Display.all().map { CGDisplayBounds($0.id) }
        last = nil
    }

    private func updateTap() {
        refresh()
        if !enabled && !wrap {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            return
        }
        guard let tap = ensureTap() else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func ensureTap() -> CFMachPort? {
        if let tap { return tap }
        guard AXIsProcessTrusted() else { return nil }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
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
            if enabled || wrap, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if type == .leftMouseDown {
            dragMayWrap = wrap && !Self.onWindowEdge(event.location)
            return pass
        }
        let now = event.location
        defer { last = event.location }
        guard enabled || wrap, !(isTouchEvent?(event) ?? false) else { return pass }

        let delta = CGPoint(x: event.getDoubleValueField(.mouseEventDeltaX),
                            y: event.getDoubleValueField(.mouseEventDeltaY))
        // While dragging, the event after a warp counts the warp itself as
        // movement: no mouse moves that far at once, so just carry on from
        // where the pointer is.
        guard hypot(delta.x, delta.y) < 300 else { return pass }
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
        if neighbours.isEmpty {
            // Off the outer side: wrap around, also while dragging a window
            // or a file along, but not a window's edge.
            guard wrap, type == .mouseMoved || (type == .leftMouseDragged && dragMayWrap), let mapped = wrapped(from: source, to: to, goingRight: goingRight)
            else { return pass }
            if debugLogging {
                FileHandle.standardError.write(
                    "wrap (\(type == .mouseMoved ? "move" : "drag")): at \(now) from \(from) delta \(delta) -> \(mapped)\n"
                        .data(using: .utf8)!)
            }
            event.location = mapped
            movePointer(to: mapped)
            return pass
        }
        guard enabled, neighbours.count == 1, let target = neighbours.first,
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

    /// Whether `point` is on the edge of the topmost window there, where a
    /// press resizes it: a few points inside or out.
    private static func onWindowEdge(_ point: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return false }
        for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict),
                  frame.insetBy(dx: -8, dy: -8).contains(point) else { continue }
            return !frame.insetBy(dx: 5, dy: 5).contains(point)
        }
        return false
    }

    /// Where the pointer comes in on the far side, if `source` is an outermost
    /// screen on that side (none further that way, at any height). Height: the
    /// same fraction with Match Screen Edges, else the same where possible.
    private func wrapped(from source: CGRect, to: CGPoint, goingRight: Bool) -> CGPoint? {
        guard let left = screens.map(\.minX).min(), let right = screens.map(\.maxX).max(),
              abs((goingRight ? source.maxX : source.minX) - (goingRight ? right : left)) < 1 else { return nil }
        let candidates = screens.filter { abs((goingRight ? $0.minX : $0.maxX) - (goingRight ? left : right)) < 1 }
        let distance = { (screen: CGRect) in max(0, screen.minY - to.y, to.y - (screen.maxY - 1)) }
        guard let target = candidates.min(by: { distance($0) < distance($1) }),
              excluded.map({ CGDisplayBounds($0) != target }) ?? true else { return nil }
        let y = enabled
            ? target.minY + min(max((to.y - source.minY) / source.height, 0), 1) * target.height
            : to.y
        let overshoot = goingRight ? to.x - source.maxX : to.x - source.minX
        return CGPoint(
            x: goingRight ? min(target.minX + overshoot, target.maxX - 1) : max(target.maxX - 1 + overshoot, target.minX),
            y: min(max(y, target.minY), target.maxY - 1).rounded(.down)
        )
    }
}
