// MouseLock: a menu bar app that confines the mouse pointer to one display.
//
// The lock is an event tap on mouse-move/drag events: whenever the pointer
// would leave the chosen display, it is clamped back to the display's edge.
// A global hotkey (Carbon RegisterEventHotKey, no extra permission needed)
// toggles the lock.

import AppKit
import Carbon.HIToolbox
import IOKit.pwr_mgt

// Hotkey that toggles the lock: Ctrl+Option+Cmd+L.
let hotKeyCode = UInt32(kVK_ANSI_L)
let hotKeyModifiers = UInt32(controlKey | optionKey | cmdKey)
let hotKeyLabel = "Ctrl+Opt+Cmd+L"

// MARK: - Displays

struct Display {
    let id: CGDirectDisplayID
    let name: String
    var isBuiltin: Bool { CGDisplayIsBuiltin(id) != 0 }

    static func all() -> [Display] {
        NSScreen.screens.compactMap { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
            return Display(id: number.uint32Value, name: screen.localizedName)
        }
    }
}

func pointerLocation() -> CGPoint {
    // Global coordinates with the origin at the top-left of the main display,
    // the same space as CGDisplayBounds and event locations.
    CGEvent(source: nil)?.location ?? .zero
}

func movePointer(to point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    // Warping normally suppresses mouse input for ~0.25s; re-associating
    // the mouse with the cursor cancels that so clamping doesn't feel sticky.
    CGAssociateMouseAndMouseCursorPosition(1)
}

// MARK: - Locker

final class Locker {
    private(set) var lockedDisplay: CGDirectDisplayID?
    private var bounds = CGRect.zero
    private var tap: CFMachPort?
    var onChange: (() -> Void)?

    var isLocked: Bool { lockedDisplay != nil }

    /// Returns false if the event tap couldn't be created (no Accessibility permission).
    func lock(to display: CGDirectDisplayID) -> Bool {
        guard let tap = ensureTap() else { return false }
        lockedDisplay = display
        bounds = CGDisplayBounds(display)
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
        onChange?()
    }

    /// Called when the display configuration changes.
    func refresh() {
        guard let display = lockedDisplay else { return }
        if Display.all().contains(where: { $0.id == display }) {
            bounds = CGDisplayBounds(display)
        } else {
            // The locked display went away; don't trap the pointer on nothing.
            unlock()
        }
    }

    private func ensureTap() -> CFMachPort? {
        if let tap { return tap }
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) else { return nil }

        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
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

        let point = event.location
        let clamped = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX - 1),
            y: min(max(point.y, bounds.minY), bounds.maxY - 1)
        )
        if clamped != point {
            event.location = clamped
            movePointer(to: clamped)
        }
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - Stay awake

/// Holds a power assertion that stops idle display sleep. That also keeps the
/// screen saver from starting, and with it the password lock that macOS
/// ties to "screen saver begins or display is turned off".
final class StayAwake {
    private var assertion: IOPMAssertionID?

    var isActive: Bool { assertion != nil }

    func set(_ active: Bool) {
        if active, assertion == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "MouseLock keeping the display awake" as CFString,
                &id
            )
            if result == kIOReturnSuccess { assertion = id }
        } else if !active, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }
}

// MARK: - Pointer visibility

// Private CoreGraphics calls. CGDisplayHideCursor normally only works for the
// frontmost app; the "SetsCursorInBackground" connection property lets a
// background app like this one hide the pointer system-wide. Undocumented,
// so a future macOS may ignore it, in which case the pointer just stays visible.
typealias CGSConnectionID = Int32
@_silgen_name("_CGSDefaultConnection")
func _CGSDefaultConnection() -> CGSConnectionID
@_silgen_name("CGSSetConnectionProperty")
func CGSSetConnectionProperty(_ connection: CGSConnectionID, _ target: CGSConnectionID,
                              _ key: CFString, _ value: CFTypeRef) -> CGError

final class PointerHider {
    private var hidden = false
    private var allowedInBackground = false

    func set(_ hide: Bool) {
        guard hide != hidden else { return }
        if hide {
            if !allowedInBackground {
                let connection = _CGSDefaultConnection()
                allowedInBackground = CGSSetConnectionProperty(
                    connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue
                ) == .success
            }
            CGDisplayHideCursor(kCGNullDirectDisplay)
        } else {
            CGDisplayShowCursor(kCGNullDirectDisplay)
        }
        hidden = hide
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let locker = Locker()
    let stayAwake = StayAwake()
    /// Stay awake even while unlocked (menu toggle).
    var keepAwakeManually = false
    let pointerHider = PointerHider()
    /// Touch-screen mode: hide the pointer while locked (menu toggle, remembered).
    var hidePointerWhileLocked: Bool {
        get { UserDefaults.standard.bool(forKey: "hidePointerWhileLocked") }
        set { UserDefaults.standard.set(newValue, forKey: "hidePointerWhileLocked") }
    }
    var statusItem: NSStatusItem!
    var lastTarget: CGDirectDisplayID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        locker.onChange = { [weak self] in self?.updateState() }
        updateState()
        registerHotKey()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.locker.refresh() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pointerHider.set(false)
    }

    func updateState() {
        stayAwake.set(locker.isLocked || keepAwakeManually)
        pointerHider.set(locker.isLocked && hidePointerWhileLocked)

        let symbol = locker.isLocked ? "lock.fill"
            : stayAwake.isActive ? "cup.and.saucer.fill"
            : "cursorarrow"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MouseLock")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let displays = Display.all()

        if let locked = locker.lockedDisplay {
            let name = displays.first { $0.id == locked }?.name ?? "display"
            let status = NSMenuItem(title: "Locked to \(name)", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(item("Unlock", #selector(unlockClicked)))
        } else {
            for display in displays {
                let title = "Lock to \(display.name)" + (display.isBuiltin ? " (built-in)" : "")
                let entry = item(title, #selector(lockClicked(_:)))
                entry.representedObject = NSNumber(value: display.id)
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        if locker.isLocked {
            let awake = NSMenuItem(title: "Keeping Display Awake (while locked)", action: nil, keyEquivalent: "")
            awake.state = .on
            awake.isEnabled = false
            menu.addItem(awake)
        } else {
            let awake = item("Keep Display Awake", #selector(keepAwakeClicked))
            awake.state = keepAwakeManually ? .on : .off
            menu.addItem(awake)
        }

        let hide = item("Hide Pointer While Locked", #selector(hidePointerClicked))
        hide.state = hidePointerWhileLocked ? .on : .off
        menu.addItem(hide)

        menu.addItem(.separator())
        let hint = NSMenuItem(title: "Toggle: \(hotKeyLabel)", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(item("Quit MouseLock", #selector(quitClicked)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func lockClicked(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        lock(to: number.uint32Value)
    }

    @objc func unlockClicked() { locker.unlock() }

    @objc func hidePointerClicked() {
        hidePointerWhileLocked.toggle()
        updateState()
    }

    @objc func keepAwakeClicked() {
        keepAwakeManually.toggle()
        updateState()
    }

    @objc func quitClicked() { NSApp.terminate(nil) }

    /// Hotkey: unlock if locked; otherwise lock to the last-used display,
    /// falling back to the first external display.
    func toggle() {
        if locker.isLocked {
            locker.unlock()
            return
        }
        let displays = Display.all()
        let target = displays.first { $0.id == lastTarget }
            ?? displays.first { !$0.isBuiltin }
        guard let target else {
            NSSound.beep()
            return
        }
        lock(to: target.id)
    }

    private func lock(to display: CGDirectDisplayID) {
        if locker.lock(to: display) {
            lastTarget = display
        } else {
            // macOS has shown (or will show) the Accessibility prompt.
            NSSound.beep()
        }
    }

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            delegate.toggle()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4D4C_434B), id: 1) // 'MLCK'
        RegisterEventHotKey(hotKeyCode, hotKeyModifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
