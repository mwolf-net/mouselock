import AppKit

func movePointer(to point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    CGAssociateMouseAndMouseCursorPosition(1)
}

/// Set MOUSELOCK_DEBUG=1 to log clamping to stderr.
let debugLogging = ProcessInfo.processInfo.environment["MOUSELOCK_DEBUG"] != nil

/// Confines the pointer to one display while locked.
final class Locker {
    private(set) var lockedDisplay: CGDirectDisplayID?
    private var bounds = CGRect.zero
    private var tap: CFMachPort?
    var onChange: (() -> Void)?
    /// Called (on the main thread) for each mouse button press or release while
    /// locked, with the event's global location and whether it was a press.
    var onClick: ((CGPoint, Bool) -> Void)?

    var isLocked: Bool { lockedDisplay != nil }

    /// Drop right-clicks and other extra buttons (middle, back/forward) while
    /// locked, so the mouse alone can't open context menus or navigate the
    /// browser. Ctrl+click still works: whoever has the keyboard is in charge.
    var blockExtraButtons = false

    /// Where the pointer was before locking (if on another display), so
    /// unlocking can put it back.
    private var returnPoint: (point: CGPoint, display: CGDirectDisplayID)?

    /// Keep the pointer off the lock screen's bottom row: pushing down there
    /// makes macOS move the Dock to that screen.
    var avoidBottomEdge = false {
        didSet { if let lockedDisplay { updateBounds(for: lockedDisplay) } }
    }
    /// Keep the pointer off the top rows: resting there reveals a hidden menu
    /// bar (in full-screen apps, or with menu bar auto-hide). One row wasn't
    /// enough in testing; four was.
    var avoidTopEdge = false {
        didSet { if let lockedDisplay { updateBounds(for: lockedDisplay) } }
    }

    private func updateBounds(for display: CGDirectDisplayID) {
        bounds = CGDisplayBounds(display)
        if avoidBottomEdge { bounds.size.height -= 1 }
        if avoidTopEdge {
            bounds.origin.y += 4
            bounds.size.height -= 4
        }
    }

    /// Returns false if the event tap couldn't be created (no Accessibility permission).
    func lock(to display: CGDirectDisplayID) -> Bool {
        guard let tap = ensureTap() else { return false }
        // Relocking to another screen keeps the original return point.
        if !isLocked {
            let point = pointerLocation()
            returnPoint = displayContaining(point)
                .flatMap { $0 == display ? nil : (point, $0) }
        }
        lockedDisplay = display
        updateBounds(for: display)
        if !bounds.contains(pointerLocation()) {
            movePointer(to: CGPoint(x: bounds.midX, y: bounds.midY))
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        onChange?()
        return true
    }

    func unlock() {
        lockedDisplay = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        // Put the pointer back where it was, or at least on that screen
        // (e.g. if its resolution changed); skip it if the screen is gone.
        if let (point, display) = returnPoint, Display.all().contains(where: { $0.id == display }) {
            let screen = CGDisplayBounds(display)
            movePointer(to: screen.contains(point) ? point : CGPoint(x: screen.midX, y: screen.midY))
        }
        returnPoint = nil
        onChange?()
    }

    private func displayContaining(_ point: CGPoint) -> CGDirectDisplayID? {
        var display = CGDirectDisplayID(0)
        var count = UInt32(0)
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else { return nil }
        return display
    }

    /// Called when the display configuration changes.
    func refresh() {
        guard let display = lockedDisplay else { return }
        if Display.all().contains(where: { $0.id == display }) {
            updateBounds(for: display)
        } else {
            // The locked display went away; don't trap the pointer on nothing.
            unlock()
        }
    }

    private func ensureTap() -> CFMachPort? {
        if let tap { return tap }
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) else { return nil }

        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let locker = Unmanaged<Locker>.fromOpaque(refcon!).takeUnretainedValue()
            return locker.handle(type: type, event: event)
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
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if isLocked, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard isLocked else { return Unmanaged.passUnretained(event) }

        switch type {
        case .otherMouseDown, .otherMouseUp:
            return blockExtraButtons ? nil : Unmanaged.passUnretained(event)
        case .rightMouseDown, .rightMouseUp:
            if blockExtraButtons { return nil }
            onClick?(event.location, type == .rightMouseDown)
            return Unmanaged.passUnretained(event)
        case .leftMouseDown, .leftMouseUp:
            onClick?(event.location, type == .leftMouseDown)
            return Unmanaged.passUnretained(event)
        default:
            break
        }

        // Only intervene when the pointer has actually left the display. At
        // edges with no neighbouring display macOS keeps it in bounds itself.
        let point = event.location
        guard !bounds.contains(point) else { return Unmanaged.passUnretained(event) }
        let clamped = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX - 1),
            y: min(max(point.y, bounds.minY), bounds.maxY - 1)
        )
        if debugLogging {
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            FileHandle.standardError.write(
                "clamp \(point) -> \(clamped) delta (\(dx), \(dy)) bounds \(bounds)\n".data(using: .utf8)!)
        }
        event.location = clamped
        movePointer(to: clamped)
        return Unmanaged.passUnretained(event)
    }
}
