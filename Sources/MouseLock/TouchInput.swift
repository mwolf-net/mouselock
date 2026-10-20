import AppKit
import IOKit

/// Adjusts input from a USB touch screen (it reports as a mouse, so macOS
/// otherwise treats touches as mouse clicks and drags):
///
/// - Remapping: macOS sometimes maps a touch screen's input onto the main
///   display, wherever the touch screen actually is. Such touches are moved
///   onto the touch screen, keeping their relative position (10% from the
///   left of the main display becomes 10% from the left of the touch screen).
/// - Drag to scroll: a one-finger drag scrolls instead of selecting text. A
///   tap still clicks, and pressing briefly before dragging still drags.
///
/// Touches are recognised by the device that sent them: a touch screen
/// reports as a mouse, but its USB device also has a HID "Touch Screen"
/// digitizer interface.
final class TouchInput {
    /// The display that is the touch screen (the lock screen); nil turns
    /// everything off.
    var touchScreen: CGDirectDisplayID? {
        didSet { updateTap() }
    }
    /// Move touches that landed on the main display onto the touch screen.
    var remap = false {
        didSet { updateTap() }
    }
    var dragToScroll = false {
        didSet { updateTap() }
    }
    /// Called (on the main thread) when a scrolling drag ends.
    var onScrollEnded: (() -> Void)?

    private var tap: CFMachPort?
    /// Whether each sending device (by registry entry ID) is a touch screen.
    private var isTouchSender: [Int64: Bool] = [:]
    /// Marks the events we post ourselves, so our tap lets them through.
    private static let replayMarker: Int64 = 0x4D4C_5449 // 'MLTI'

    // Drag to scroll: a press is held back until it's clear whether it's a
    // tap (click), a drag (scroll) or a press-and-hold (normal drag).
    private enum Gesture {
        case none
        case pending(down: CGEvent, start: CGPoint)
        case scrolling(last: CGPoint)
        case dragging
    }
    private var gesture = Gesture.none
    private var holdTimer: DispatchWorkItem?
    /// Fractional scroll amounts carried over between events.
    private var scrollRemainder = CGPoint.zero
    /// Movement (in points) that turns a press into a scroll.
    private static let scrollThreshold: CGFloat = 8
    /// Holding this long without moving turns a press into a normal drag.
    private static let holdDelay: TimeInterval = 0.4

    private func updateTap() {
        let active = touchScreen != nil && (remap || dragToScroll)
        if !active {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            gesture = .none
            return
        }
        guard let tap = ensureTap() else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func ensureTap() -> CFMachPort? {
        if let tap { return tap }
        guard AXIsProcessTrusted() else { return nil }

        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let touchInput = Unmanaged<TouchInput>.fromOpaque(refcon!).takeUnretainedValue()
            return touchInput.handle(type: type, event: event)
        }
        // At the HID level, so this runs before the lock's and smart touch's
        // session-level taps, and before macOS positions the pointer.
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
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
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        // Skip events we posted ourselves, including smart touch's replays.
        let marker = event.getIntegerValueField(.eventSourceUserData)
        guard let touchScreen, marker != Self.replayMarker, marker != SmartTouch.replayMarker,
              isTouchScreen(sender: event.getIntegerValueField(senderIDField)) else { return pass }

        if remap { remapToTouchScreen(event, touchScreen: touchScreen) }
        return dragToScroll ? handleGesture(type: type, event: event) : pass
    }

    private func remapToTouchScreen(_ event: CGEvent, touchScreen: CGDirectDisplayID) {
        // Only remap touches that landed on the main display: depending on
        // how the screen is connected, macOS sometimes gets it right itself.
        let main = CGDisplayBounds(CGMainDisplayID())
        let target = CGDisplayBounds(touchScreen)
        let point = event.location
        guard main != target, main.contains(point), main.width > 0, main.height > 0 else { return }
        let mapped = CGPoint(
            x: target.minX + (point.x - main.minX) / main.width * target.width,
            y: target.minY + (point.y - main.minY) / main.height * target.height
        )
        if debugLogging {
            FileHandle.standardError.write("touch \(point) -> \(mapped)\n".data(using: .utf8)!)
        }
        event.location = mapped
    }

    // MARK: Drag to scroll

    private func handleGesture(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let point = event.location

        switch (type, gesture) {
        case (.leftMouseDown, _):
            guard let down = event.copy() else { return pass }
            gesture = .pending(down: down, start: point)
            let timer = DispatchWorkItem { [weak self] in self?.pressHeld() }
            holdTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: timer)
            return nil

        case (.leftMouseDragged, .pending(_, let start)):
            guard hypot(point.x - start.x, point.y - start.y) > Self.scrollThreshold else { return nil }
            holdTimer?.cancel()
            scrollRemainder = .zero
            gesture = .scrolling(last: start)
            log("scrolling")
            return scroll(to: point)

        case (.leftMouseDragged, .scrolling):
            return scroll(to: point)

        case (.leftMouseUp, .pending(let down, _)):
            // A tap: deliver the held press, then this release.
            holdTimer?.cancel()
            gesture = .none
            post(down)
            event.copy().map(post)
            return nil

        case (.leftMouseUp, .scrolling):
            gesture = .none
            log("scroll ended")
            onScrollEnded?()
            return nil

        case (.leftMouseUp, _):
            gesture = .none
            return pass

        default:
            return pass
        }
    }

    /// Pressed without moving for a while: deliver the press, so that what
    /// follows is an ordinary drag (selecting text, moving things).
    private func pressHeld() {
        guard case .pending(let down, _) = gesture else { return }
        log("press held; normal drag")
        gesture = .dragging
        post(down)
    }

    /// Scrolls by the finger's movement since the last event, and swallows
    /// the drag event. The content follows the finger.
    private func scroll(to point: CGPoint) -> Unmanaged<CGEvent>? {
        guard case .scrolling(let last) = gesture else { return nil }
        gesture = .scrolling(last: point)
        let dx = point.x - last.x + scrollRemainder.x
        let dy = point.y - last.y + scrollRemainder.y
        let wholeX = dx.rounded(.towardZero), wholeY = dy.rounded(.towardZero)
        scrollRemainder = CGPoint(x: dx - wholeX, y: dy - wholeY)
        guard wholeX != 0 || wholeY != 0,
              let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: Int32(wholeY), wheel2: Int32(wholeX), wheel3: 0) else { return nil }
        scroll.location = point
        post(scroll)
        return nil
    }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
        event.post(tap: .cghidEventTap)
    }

    private func log(_ message: String) {
        guard debugLogging else { return }
        FileHandle.standardError.write("touch input: \(message)\n".data(using: .utf8)!)
    }

    /// Whether the event came from a touch screen.
    func isTouch(_ event: CGEvent) -> Bool {
        isTouchScreen(sender: event.getIntegerValueField(senderIDField))
    }

    private func isTouchScreen(sender: Int64) -> Bool {
        if let known = isTouchSender[sender] { return known }
        let result = Self.lookUpTouchScreen(sender: sender)
        isTouchSender[sender] = result
        if debugLogging {
            FileHandle.standardError.write("sender \(sender): touch screen \(result)\n".data(using: .utf8)!)
        }
        return result
    }

    /// Whether the sending service, or the USB device it belongs to, has a
    /// HID Touch Screen (digitizer page 0x0D, usage 0x04) interface.
    private static func lookUpTouchScreen(sender: Int64) -> Bool {
        guard sender != 0 else { return false }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(UInt64(sender)))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        if isTouchScreenInterface(service) { return true }

        // Walk up to the USB device, then look for a touch screen interface
        // anywhere below it.
        var entry = service
        IOObjectRetain(entry)
        for _ in 0..<8 {
            if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 {
                defer { IOObjectRelease(entry) }
                return hasTouchScreenInterface(below: entry)
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard result == KERN_SUCCESS else { return false }
            entry = parent
        }
        IOObjectRelease(entry)
        return false
    }

    // MARK: Detecting touch screens

    /// Whether a USB touch screen is connected. (USB only: a MacBook's Touch
    /// Bar is a touch screen digitizer too, but on an internal bus.)
    static func touchScreenConnected() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, touchScreenMatching(), &iterator) == KERN_SUCCESS
        else { return false }
        defer { IOObjectRelease(iterator) }
        var found = false
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            if !found && hasUSBDeviceAncestor(entry) { found = true }
            IOObjectRelease(entry)
        }
        return found
    }

    private var notifyPort: IONotificationPortRef?

    /// Calls `handler` (on the main thread) whenever a touch screen interface
    /// appears or disappears.
    func observeTouchScreens(_ handler: @escaping () -> Void) {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        onTouchScreensChanged = handler
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            // Drain the iterator to re-arm the notification.
            while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
            let mapper = Unmanaged<TouchInput>.fromOpaque(refcon!).takeUnretainedValue()
            mapper.onTouchScreensChanged?()
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, type, Self.touchScreenMatching(), callback, refcon,
                                                &iterator) == KERN_SUCCESS {
                while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
            }
        }
    }

    private var onTouchScreensChanged: (() -> Void)?

    private static func touchScreenMatching() -> CFDictionary {
        [kIOPropertyMatchKey: [kIOHIDPrimaryUsagePageKey: 0x0D, kIOHIDPrimaryUsageKey: 0x04]] as CFDictionary
    }

    private static func hasUSBDeviceAncestor(_ entry: io_registry_entry_t) -> Bool {
        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<8 {
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 { return true }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
            IOObjectRelease(current)
            current = parent
        }
        return false
    }

    private static func hasTouchScreenInterface(below device: io_registry_entry_t) -> Bool {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(device, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if isTouchScreenInterface(entry) { return true }
        }
        return false
    }

    private static func isTouchScreenInterface(_ entry: io_registry_entry_t) -> Bool {
        func intProperty(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
        }
        return intProperty(kIOHIDPrimaryUsagePageKey) == 0x0D && intProperty(kIOHIDPrimaryUsageKey) == 0x04
    }
}
