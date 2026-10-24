import AppKit

/// Smart touchscreen mode: while unlocked, a tap by touch (told apart from
/// the mouse by the device it comes from, wherever it lands) is delivered as
/// a normal click to the window under it, then the pointer and keyboard focus
/// go back to where they were, so whoever uses the mouse can carry on. That
/// works on a single screen too.
///
/// A click on an inactive window often only activates it, so a tap on a
/// window that isn't focused is held back, the window is focused via the
/// Accessibility API, and then the click is replayed.
final class SmartTouch {
    var enabled = false {
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
    /// How long after restoring focus to check that it took.
    private static let checkDelay: TimeInterval = 0.1

    /// Where the mouse last put the pointer.
    private var home: CGPoint?
    /// Focus to restore after a burst of taps.
    private var savedFocus: Focus?
    /// The app tapped on the touch screen during a burst of taps.
    private var touchedPID: pid_t?
    private var restoreWork: DispatchWorkItem?
    /// Whether a touch press hasn't been released yet.
    private var tapInProgress = false

    /// Whether a touch moved the pointer last (not the mouse since): it's
    /// only there on behalf of the touch, so the app hides it meanwhile.
    private(set) var pointerFromTouch = false {
        didSet { if pointerFromTouch != oldValue { onPointerFromTouchChanged?() } }
    }
    var onPointerFromTouchChanged: (() -> Void)?

    /// Whether the pointer was left (hidden) where a touch put it, until the
    /// mouse moves: that keeps hover effects, like a menu the tap opened.
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
        if !enabled {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            restoreWork?.cancel()
            restoreWork = nil
            savedFocus = nil
            touchedPID = nil
            held = []
            tapInProgress = false
            parked = false
            pointerFromTouch = false
            return true
        }
        guard let tap = ensureTap() else { return false }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func ensureTap() -> CFMachPort? {
        if let tap, EventTaps.isLive(tap) { return tap }
        guard EventTaps.permitted else {
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
            return nil
        }

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
        EventTaps.add(tap)
        return tap
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if enabled, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        let marker = event.getIntegerValueField(.eventSourceUserData)
        guard enabled, marker != Self.replayMarker else { return pass }
        let point = event.location
        // Touches held back and replayed by TouchInput come from MouseLock,
        // not the touch screen, but they're touches all the same.
        let isTouch = marker == TouchInput.replayMarker || (isTouchEvent?(event) ?? false)
        if parked, !isTouch, type == .mouseMoved || type == .leftMouseDragged || type == .leftMouseDown,
           let home {
            // The mouse moves on (or clicks) from where it left the pointer.
            let moved = CGPoint(x: home.x + event.getDoubleValueField(.mouseEventDeltaX),
                                y: home.y + event.getDoubleValueField(.mouseEventDeltaY))
            parked = false
            event.location = moved
            movePointer(to: moved)
            self.home = moved
            pointerFromTouch = false
            return pass
        }
        if type == .mouseMoved || type == .leftMouseDragged || type == .leftMouseDown {
            pointerFromTouch = isTouch
        }

        switch type {
        case .mouseMoved:
            if !isTouch {
                home = point
                parked = false
            }
            return pass

        case .leftMouseDown:
            guard isTouch else { return pass }
            tapInProgress = true
            restoreWork?.cancel()
            restoreWork = nil
            if savedFocus == nil { savedFocus = currentFocus() }

            let target = windowAt(point)
            if let target { touchedPID = target.pid }
            guard let target, !isFocused(target) else {
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
        guard enabled else { return }
        scheduleRestore()
    }

    private func scheduleRestore() {
        restoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restore() }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay, execute: work)
    }

    private func restore() {
        restoreWork = nil
        // If a touch moved the pointer last (the mouse may have moved it
        // since), leave it there, hidden, so hover effects like drop-down
        // menus stay open: it goes home as soon as the mouse moves.
        if pointerFromTouch, home != nil {
            parked = true
        }
        // A tap may have opened a menu (say the app's menu bar): handing the
        // keyboard back would deactivate the app, closing it. Wait till it's
        // closed (an item picked, or dismissed).
        if savedFocus != nil, Self.menuOpen() {
            log("menu open; restoring focus once it's closed")
            let work = DispatchWorkItem { [weak self] in self?.restore() }
            restoreWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            return
        }
        if let savedFocus, let touchedPID, touchedPID != savedFocus.pid,
           secureInputPID() == touchedPID {
            // A tap in a password field: that's for typing, so leave the
            // keyboard with it.
            log("password field in pid \(touchedPID); leaving the keyboard there")
        } else if let savedFocus, !isFocused(savedFocus) {
            log("restoring focus to pid \(savedFocus.pid)")
            focus(savedFocus)
            if let touchedPID, touchedPID != savedFocus.pid {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.checkDelay) { [weak self] in
                    self?.checkRestored(savedFocus, touched: touchedPID)
                }
            }
        }
        savedFocus = nil
        touchedPID = nil
    }

    /// Focusing via the Accessibility API doesn't always take. In particular,
    /// when a password field in the touched app gets focus around the time
    /// focus is restored (say a dialog that opens a little late), that app
    /// keeps the keyboard and secure input while the other app is frontmost.
    /// A password field is for typing, so then hand the keyboard to it
    /// properly; otherwise try again to restore focus, the normal way.
    /// Either way MouseLock activates itself first, so the app losing focus
    /// notices.
    private func checkRestored(_ target: Focus, touched: pid_t) {
        // A new tap in the meantime will restore focus itself.
        guard savedFocus == nil, !tapInProgress else { return }
        let holder = secureInputPID()
        let focused = isFocused(target)
        log("focus check: focused \(focused), secure input pid \(holder.map(String.init) ?? "none")")
        let pid: pid_t
        if holder == touched {
            log("password field in pid \(touched); giving it the keyboard")
            pid = touched
        } else if !focused {
            log("focus didn't take; activating pid \(target.pid)")
            pid = target.pid
        } else {
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication(processIdentifier: pid)?.activate()
        if pid == target.pid { focus(target) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.checkDelay) { [weak self] in
            guard let self else { return }
            log("after activating pid \(pid): frontmost \(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0), "
                + "secure input pid \(secureInputPID().map(String.init) ?? "none")")
        }
    }

    /// The process that has secure input (keyboard entry) on, if any.
    private func secureInputPID() -> pid_t? {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["kCGSSessionSecureInputPID"] as? NSNumber).map { pid_t($0.int32Value) }
    }

    /// Whether the frontmost app has a menu open: a window of its at the
    /// level macOS uses for menus.
    private static func menuOpen() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return list.contains { info in
            (info[kCGWindowLayer as String] as? Int) == menuLevel && (info[kCGWindowOwnerPID as String] as? pid_t) == pid
        }
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

    private func log(_ message: String) {
        guard debugLogging else { return }
        FileHandle.standardError.write("smart touch: \(message)\n".data(using: .utf8)!)
    }
}
