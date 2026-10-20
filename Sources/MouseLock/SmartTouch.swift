import AppKit

/// Smart touchscreen mode: while unlocked, a tap on the touch screen is
/// delivered as a normal click to the window under it, then the pointer and
/// keyboard focus go back to where they were, so the main user on the other
/// screen can carry on.
///
/// A click on an inactive window often only activates it, so a tap on a
/// window that isn't focused is held back, the window is focused via the
/// Accessibility API, and then the click is replayed.
final class SmartTouch {
    /// The touch screen; nil turns the mode off.
    var screen: CGDirectDisplayID? {
        didSet { updateTap() }
    }

    private var tap: CFMachPort?
    /// Marks the clicks we replay, so our own tap lets them through.
    static let replayMarker: Int64 = 0x4D4C_5354 // 'MLST'
    /// How long to wait for a window to become focused before clicking anyway.
    private static let focusTimeout: TimeInterval = 0.25
    /// Delay after a tap before restoring pointer and focus, so the app has
    /// handled the click, and so quick successive taps count as one burst.
    /// (Apps such as Chrome ignore clicks while inactive, so they have to be
    /// activated briefly.)
    private static let restoreDelay: TimeInterval = 0.15

    /// Where the pointer was before it came to the touch screen.
    private var home: CGPoint?
    /// Focus to restore after a burst of taps.
    private var savedFocus: Focus?
    private var restoreWork: DispatchWorkItem?
    /// Whether a press on the touch screen hasn't been released yet.
    private var tapInProgress = false

    /// Whether the pointer is on the touch screen. In this mode it only goes
    /// there on behalf of a touch, so the app hides it meanwhile.
    private(set) var pointerOnScreen = false {
        didSet { if pointerOnScreen != oldValue { onPointerOnScreenChanged?() } }
    }
    var onPointerOnScreenChanged: (() -> Void)?

    /// Keep the mouse and trackpad off the touch screen, so only touches go
    /// there. Needs `isTouchEvent` to tell them apart.
    var keepMouseOff = false
    /// Whether the pointer was left on the touch screen after a touch.
    private var parked = false
    var isTouchEvent: ((CGEvent) -> Bool)?
    /// A press held back while its window gets focused, plus what followed it.
    private var held: [CGEvent] = []

    private struct Focus {
        let pid: pid_t
        let window: AXUIElement?
    }

    /// Returns false if the event tap couldn't be created (no Accessibility permission).
    @discardableResult
    private func updateTap() -> Bool {
        if screen == nil {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            restoreWork?.cancel()
            restoreWork = nil
            savedFocus = nil
            held = []
            tapInProgress = false
            parked = false
            pointerOnScreen = false
            return true
        }
        guard let tap = ensureTap() else { return false }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func ensureTap() -> CFMachPort? {
        if let tap { return tap }
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) else { return nil }

        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let smartTouch = Unmanaged<SmartTouch>.fromOpaque(refcon!).takeUnretainedValue()
            return smartTouch.handle(type: type, event: event)
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
            if screen != nil, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard let screen, event.getIntegerValueField(.eventSourceUserData) != Self.replayMarker else {
            return pass
        }
        let point = event.location
        let bounds = CGDisplayBounds(screen)
        if keepMouseOff, bounds.contains(point), type == .mouseMoved || type == .leftMouseDragged,
           !(isTouchEvent?(event) ?? true) {
            // The mouse tried to move onto the touch screen: keep it off. If
            // the pointer was parked there after a touch, send it home.
            let stay = parked ? (home ?? pointOffTouchScreen(point, bounds: bounds))
                : pointOffTouchScreen(point, bounds: bounds)
            parked = false
            event.location = stay
            movePointer(to: stay)
            home = stay
            pointerOnScreen = false
            return pass
        }
        let onTouchScreen = bounds.contains(point)
        pointerOnScreen = onTouchScreen

        switch type {
        case .mouseMoved:
            if !onTouchScreen { home = point }
            return pass

        case .leftMouseDown:
            guard onTouchScreen else { return pass }
            tapInProgress = true
            restoreWork?.cancel()
            restoreWork = nil
            if savedFocus == nil { savedFocus = currentFocus() }

            guard let target = windowAt(point), !isFocused(target) else {
                log("tap at \(point): window already focused")
                return pass
            }
            log("tap at \(point): focusing pid \(target.pid) first")
            held = [event.copy()].compactMap { $0 }
            focus(target)
            waitForFocus(target, deadline: Date() + Self.focusTimeout)
            return nil

        case .leftMouseDragged:
            if !held.isEmpty {
                event.copy().map { held.append($0) }
                return nil
            }
            return pass

        case .leftMouseUp:
            if !held.isEmpty {
                event.copy().map { held.append($0) }
                return nil
            }
            if tapInProgress {
                tapInProgress = false
                scheduleRestore()
            }
            return pass

        default:
            return pass
        }
    }

    private func waitForFocus(_ target: Focus, deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self, !held.isEmpty else { return }
            if isFocused(target) || Date() > deadline {
                log(isFocused(target) ? "focused; replaying click" : "focus timed out; replaying click")
                replayHeld()
            } else {
                waitForFocus(target, deadline: deadline)
            }
        }
    }

    private func replayHeld() {
        let events = held
        held = []
        for event in events {
            postMarked(event, marker: Self.replayMarker)
        }
        if events.contains(where: { $0.type == .leftMouseUp }) {
            tapInProgress = false
            scheduleRestore()
        }
    }

    /// A touch gesture that didn't click (such as a scroll) ended: send the
    /// pointer back, if this mode is on.
    func touchEnded() {
        guard screen != nil else { return }
        scheduleRestore()
    }

    /// Where to keep the mouse when it tries to enter the touch screen at
    /// `point`: slide along the edge where possible, else stay put.
    private func pointOffTouchScreen(_ point: CGPoint, bounds: CGRect) -> CGPoint {
        let main = CGDisplayBounds(CGMainDisplayID())
        let from = home ?? CGPoint(x: main.midX, y: main.midY)
        for candidate in [CGPoint(x: from.x, y: point.y), CGPoint(x: point.x, y: from.y)]
        where !bounds.contains(candidate) && isOnSomeDisplay(candidate) {
            return candidate
        }
        return from
    }

    private func isOnSomeDisplay(_ point: CGPoint) -> Bool {
        var display = CGDirectDisplayID(0)
        var count = UInt32(0)
        return CGGetDisplaysWithPoint(point, 1, &display, &count) == .success && count > 0
    }

    private func scheduleRestore() {
        restoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restore() }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay, execute: work)
    }

    private func restore() {
        restoreWork = nil
        // Only move the pointer if it's still on the touch screen (the main
        // user may have moved the mouse away in the meantime). With the mouse
        // kept off the touch screen, leave it parked there (hidden) instead,
        // so hover effects like drop-down menus stay open: it goes home as
        // soon as the mouse moves.
        if let screen, let home, CGDisplayBounds(screen).contains(pointerLocation()) {
            if keepMouseOff {
                parked = true
            } else {
                movePointer(to: home)
            }
        }
        pointerOnScreen = screen.map { CGDisplayBounds($0).contains(pointerLocation()) } ?? false
        if let savedFocus, !isFocused(savedFocus) {
            log("restoring focus to pid \(savedFocus.pid)")
            focus(savedFocus)
        }
        savedFocus = nil
    }

    // MARK: Focus via the Accessibility API

    private func currentFocus() -> Focus? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        return Focus(pid: app.processIdentifier, window: copyElement(element, kAXFocusedWindowAttribute))
    }

    /// The topmost normal window under `point`. Looked up in the window list
    /// rather than by Accessibility hit-testing, which can make browsers
    /// switch on their (slow) accessibility support for web content.
    private func windowAt(_ point: CGPoint) -> Focus? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(point),
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            return Focus(pid: pid, window: axWindow(pid: pid, frame: bounds))
        }
        return nil
    }

    /// The app's Accessibility window with the given frame.
    private func axWindow(pid: pid_t, frame: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { window in
            guard let position = copyPoint(window, kAXPositionAttribute),
                  let size = copySize(window, kAXSizeAttribute) else { return false }
            return abs(position.x - frame.minX) < 2 && abs(position.y - frame.minY) < 2
                && abs(size.width - frame.width) < 2 && abs(size.height - frame.height) < 2
        }
    }

    private func isFocused(_ target: Focus) -> Bool {
        guard let current = currentFocus(), current.pid == target.pid else { return false }
        guard let window = target.window else { return true }
        return current.window.map { CFEqual($0, window) } ?? false
    }

    private func focus(_ target: Focus) {
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window = target.window {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copyPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        var point = CGPoint.zero
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func copySize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private func log(_ message: String) {
        guard debugLogging else { return }
        FileHandle.standardError.write("smart touch: \(message)\n".data(using: .utf8)!)
    }
}
