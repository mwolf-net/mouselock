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

// Warping the pointer normally makes macOS ignore mouse input for ~0.25s,
// which swallows the start of a swipe right after a clamp. This call turns
// that off for the session; Swift marks it unavailable, but the symbol is
// still exported and works, so declare it by name.
@_silgen_name("CGSetLocalEventsSuppressionInterval")
func CGSetLocalEventsSuppressionIntervalCompat(_ seconds: CFTimeInterval) -> CGError

func movePointer(to point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    CGAssociateMouseAndMouseCursorPosition(1)
}

/// Set MOUSELOCK_DEBUG=1 to log clamping to stderr.
let debugLogging = ProcessInfo.processInfo.environment["MOUSELOCK_DEBUG"] != nil

// MARK: - Locker

final class Locker {
    private(set) var lockedDisplay: CGDirectDisplayID?
    private var bounds = CGRect.zero
    private var tap: CFMachPort?
    var onChange: (() -> Void)?
    /// Called (on the main thread) for each mouse button press or release while
    /// locked, with the event's global location and whether it was a press.
    var onClick: ((CGPoint, Bool) -> Void)?

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

        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
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
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            onClick?(event.location, type == .leftMouseDown || type == .rightMouseDown)
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

    var isHidden: Bool { hidden }

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

    /// Other apps can make the pointer visible again (e.g. when a click
    /// activates them or changes the cursor shape); hide it once more.
    func reassert() {
        guard hidden else { return }
        CGDisplayShowCursor(kCGNullDirectDisplay)
        CGDisplayHideCursor(kCGNullDirectDisplay)
    }
}

// MARK: - Click marker

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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let locker = Locker()
    let stayAwake = StayAwake()
    /// Stay awake even while unlocked (menu toggle).
    var keepAwakeManually = false
    let pointerHider = PointerHider()
    let clickMarker = ClickMarker()
    /// Touch-screen mode: hide the pointer while locked (menu toggle, remembered).
    var hidePointerWhileLocked: Bool {
        get { UserDefaults.standard.bool(forKey: "hidePointerWhileLocked") }
        set { UserDefaults.standard.set(newValue, forKey: "hidePointerWhileLocked") }
    }
    var statusItem: NSStatusItem!
    var lastTarget: CGDirectDisplayID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = CGSetLocalEventsSuppressionIntervalCompat(0)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        locker.onChange = { [weak self] in self?.updateState() }
        locker.onClick = { [weak self] point, isPress in
            guard let self else { return }
            reassertHiddenPointer()
            if isPress && pointerHider.isHidden { clickMarker.show(at: point) }
        }
        updateState()
        registerHotKey()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.locker.refresh() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.reassertHiddenPointer() }
    }

    /// Re-hide right away and again shortly after, once the clicked app has
    /// finished reacting (activating, changing the cursor shape).
    func reassertHiddenPointer() {
        for delay in [0.0, 0.02, 0.05, 0.1, 0.2, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.pointerHider.reassert()
            }
        }
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
