import AppKit
import IOKit

/// macOS sometimes maps a USB touch screen's input onto the main display,
/// wherever the touch screen actually is. This moves such touches onto it,
/// keeping their relative position (10% from the left of the main display
/// becomes 10% from the left of the touch screen).
///
/// Touches are recognised by the device that sent them: a touch screen
/// reports as a mouse, but its USB device also has a HID "Touch Screen"
/// digitizer interface.
final class TouchMapper {
    /// The display that is the touch screen (the lock screen); nil or the
    /// main display turns mapping off.
    var touchScreen: CGDirectDisplayID? {
        didSet { updateTap() }
    }

    private var tap: CFMachPort?
    /// Whether each sending device (by registry entry ID) is a touch screen.
    private var isTouchSender: [Int64: Bool] = [:]

    private func updateTap() {
        let active = touchScreen.map { $0 != CGMainDisplayID() } ?? false
        if !active {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
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
            let mapper = Unmanaged<TouchMapper>.fromOpaque(refcon!).takeUnretainedValue()
            return mapper.handle(type: type, event: event)
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
        guard let touchScreen else { return pass }
        let sender = event.getIntegerValueField(senderIDField)
        guard isTouchScreen(sender: sender) else { return pass }

        // Only remap touches that landed on the main display: depending on
        // how the screen is connected, macOS sometimes gets it right itself.
        let main = CGDisplayBounds(CGMainDisplayID())
        let target = CGDisplayBounds(touchScreen)
        let point = event.location
        guard main != target, main.contains(point), main.width > 0, main.height > 0 else { return pass }
        let mapped = CGPoint(
            x: target.minX + (point.x - main.minX) / main.width * target.width,
            y: target.minY + (point.y - main.minY) / main.height * target.height
        )
        if debugLogging {
            FileHandle.standardError.write("touch \(point) -> \(mapped)\n".data(using: .utf8)!)
        }
        event.location = mapped
        return pass
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
            let mapper = Unmanaged<TouchMapper>.fromOpaque(refcon!).takeUnretainedValue()
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
