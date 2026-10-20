import AppKit
import Carbon.HIToolbox
import ServiceManagement

// Hotkey that toggles the lock: Ctrl+Option+Cmd+L.
let hotKeyCode = UInt32(kVK_ANSI_L)
let hotKeyModifiers = UInt32(controlKey | optionKey | cmdKey)
// The same shortcut, for display in the menu.
let hotKeyEquivalent = "l"
let hotKeyEquivalentModifiers: NSEvent.ModifierFlags = [.control, .option, .command]

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let locker = Locker()
    let stayAwake = StayAwake()
    /// Stay awake even while unlocked (menu toggle).
    var keepAwakeManually = false
    let pointerHider = PointerHider()
    let clickMarker = ClickMarker()
    let smartTouch = SmartTouch()
    let touchMapper = TouchMapper()

    // Touch-screen settings are stored per screen (as a set of display UUIDs
    // per key), so they're off for any screen not seen before.
    static let hidePointerKey = "hidePointerScreens"
    static let smartTouchKey = "smartTouchScreens"

    func isEnabled(_ key: String, on display: CGDirectDisplayID?) -> Bool {
        guard let display, let uuid = displayUUID(display) else { return false }
        return UserDefaults.standard.stringArray(forKey: key)?.contains(uuid) ?? false
    }

    /// Touchscreen Adjust: on by default when a USB touch screen is connected,
    /// unless the user picked on or off for this screen.
    static let touchAdjustKey = "touchscreenAdjust"

    func touchAdjust(on display: CGDirectDisplayID?) -> Bool {
        if let display, let uuid = displayUUID(display),
           let choices = UserDefaults.standard.dictionary(forKey: Self.touchAdjustKey) as? [String: Bool],
           let choice = choices[uuid] {
            return choice
        }
        return TouchMapper.touchScreenConnected()
    }

    func toggle(_ key: String, on display: CGDirectDisplayID?) {
        guard let display, let uuid = displayUUID(display) else { return }
        var uuids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        uuids.formSymmetricDifference([uuid])
        UserDefaults.standard.set(uuids.sorted(), forKey: key)
    }

    /// Keep the pointer off the lock screen's bottom row while locked
    /// (menu toggle, remembered, on by default).
    var keepDockOff: Bool {
        get { UserDefaults.standard.bool(forKey: "keepDockOffLockScreen") }
        set { UserDefaults.standard.set(newValue, forKey: "keepDockOffLockScreen") }
    }
    /// Keep the pointer off the lock screen's top row while locked
    /// (menu toggle, remembered, on by default).
    var keepMenuBarHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "keepMenuBarHiddenOnLockScreen") }
        set { UserDefaults.standard.set(newValue, forKey: "keepMenuBarHiddenOnLockScreen") }
    }
    /// Block right-clicks and extra buttons while locked (menu toggle,
    /// remembered, on by default).
    var blockExtraButtons: Bool {
        get { UserDefaults.standard.bool(forKey: "blockExtraButtons") }
        set { UserDefaults.standard.set(newValue, forKey: "blockExtraButtons") }
    }
    var statusItem: NSStatusItem!
    /// The display the pointer gets locked to.
    var lockScreen: CGDirectDisplayID?
    /// The lock screen picked in the menu, by the display's stable UUID
    /// (display IDs can change across reboots and reconnects). Remembered.
    var chosenLockScreenUUID: String? {
        get { UserDefaults.standard.string(forKey: "lockScreenUUID") }
        set { UserDefaults.standard.set(newValue, forKey: "lockScreenUUID") }
    }

    /// The chosen lock screen, if it's connected.
    func chosenLockScreen() -> CGDirectDisplayID? {
        guard let uuid = chosenLockScreenUUID else { return nil }
        return Display.all().first { displayUUID($0.id) == uuid }?.id
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = CGSetLocalEventsSuppressionIntervalCompat(0)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        // Otherwise AppKit enables every item with a target, ignoring isEnabled.
        menu.autoenablesItems = false
        statusItem.menu = menu

        UserDefaults.standard.register(defaults: [
            "keepDockOffLockScreen": true,
            "keepMenuBarHiddenOnLockScreen": true,
            "blockExtraButtons": true,
        ])
        locker.blockExtraButtons = blockExtraButtons
        locker.avoidBottomEdge = keepDockOff
        locker.avoidTopEdge = keepMenuBarHidden
        lockScreen = chosenLockScreen() ?? defaultLockScreen()
        locker.onChange = { [weak self] in self?.updateState() }
        locker.onClick = { [weak self] point, isPress in
            guard let self else { return }
            reassertHiddenPointer()
            if isPress && pointerHider.isHidden { clickMarker.show(at: point) }
        }
        updateState()
        registerHotKey()
        touchMapper.observeTouchScreens { [weak self] in
            if debugLogging {
                FileHandle.standardError.write("touch screens changed; connected: \(TouchMapper.touchScreenConnected())\n".data(using: .utf8)!)
            }
            self?.updateState()
        }
        if debugLogging {
            FileHandle.standardError.write("touch screen connected: \(TouchMapper.touchScreenConnected())\n".data(using: .utf8)!)
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.locker.refresh()
            self?.revalidateLockScreen()
        }

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
        pointerHider.set(isEnabled(Self.hidePointerKey, on: locker.lockedDisplay))
        // Smart touch only applies while unlocked: when locked, everyone is
        // on the lock screen anyway.
        // A touch screen's input may land on the main display; move it to
        // the lock screen, which is where a touch screen would be.
        touchMapper.touchScreen = touchAdjust(on: lockScreen) ? lockScreen : nil
        let touchScreen = locker.isLocked ? nil : lockScreen
        smartTouch.screen = isEnabled(Self.smartTouchKey, on: touchScreen) ? touchScreen : nil

        let symbol = locker.isLocked ? "lock.fill"
            : stayAwake.isActive ? "cup.and.saucer.fill"
            : "cursorarrow"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MouseLock")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    /// The external display if there is a built-in one (a laptop). Otherwise,
    /// with no clear external display, the one the pointer isn't on right now.
    func defaultLockScreen() -> CGDirectDisplayID? {
        let displays = Display.all()
        let candidates = displays.contains { $0.isBuiltin } ? displays.filter { !$0.isBuiltin } : displays
        let pointer = pointerLocation()
        let choice = candidates.first { !CGDisplayBounds($0.id).contains(pointer) }
            ?? candidates.first ?? displays.first
        return choice?.id
    }

    /// After a display change: use the chosen lock screen if it's (back)
    /// connected. Otherwise fall back to the default if the lock screen is
    /// gone, or if it was only the built-in one by default and an external
    /// display has appeared.
    func revalidateLockScreen() {
        defer { updateState() }
        if let chosen = chosenLockScreen() {
            lockScreen = chosen
            return
        }
        let current = Display.all().first { $0.id == lockScreen }
        if current?.isBuiltin ?? true {
            lockScreen = defaultLockScreen()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let displays = Display.all()

        let header = NSMenuItem(title: "Lock Screen", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.toolTip = "The screen the pointer gets locked to. Usually the second screen for customers or guests; if it's a touch screen, the touch options below apply to it."
        menu.addItem(header)
        for display in displays {
            let title = display.name + (display.isBuiltin ? " (built-in)" : "")
            let entry = item(title, #selector(lockScreenClicked(_:)))
            entry.representedObject = NSNumber(value: display.id)
            entry.state = display.id == lockScreen ? .on : .off
            entry.indentationLevel = 1
            entry.isEnabled = canLock
            entry.toolTip = "Use this screen as the lock screen. Your choice is remembered whenever this screen is connected."
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        let toggleTitle = locker.isLocked ? "Unlock Pointer"
            : canLock ? "Lock Pointer"
            : "Lock Pointer (needs a second screen)"
        let toggleItem = item(toggleTitle, #selector(toggleClicked))
        toggleItem.keyEquivalent = hotKeyEquivalent
        toggleItem.keyEquivalentModifierMask = hotKeyEquivalentModifiers
        toggleItem.isEnabled = locker.isLocked || canLock
        toggleItem.toolTip = locker.isLocked
            ? "Release the pointer and put it back where it was before locking."
            : "Move the pointer to the lock screen and keep it there: moving the mouse can't take it off. Only the keyboard shortcut unlocks."
        menu.addItem(toggleItem)

        menu.addItem(.separator())
        if locker.isLocked {
            let awake = NSMenuItem(title: "Keeping Display Awake (while locked)", action: nil, keyEquivalent: "")
            awake.state = .on
            awake.isEnabled = false
            awake.toolTip = "While locked, the display never sleeps and the screen saver and idle password lock don't start."
            menu.addItem(awake)
        } else {
            let awake = item("Keep Display Awake", #selector(keepAwakeClicked))
            awake.state = keepAwakeManually ? .on : .off
            awake.toolTip = "Keep the display awake (no screen saver, display sleep or idle password lock) without locking the pointer. Always on while locked. Resets when MouseLock restarts."
            menu.addItem(awake)
        }

        // Remembered per screen (see isEnabled(_:on:)), without saying so.
        let hide = item("Hide Pointer When Locked", #selector(hidePointerClicked))
        hide.state = isEnabled(Self.hidePointerKey, on: lockScreen) ? .on : .off
        hide.isEnabled = lockScreen != nil
        hide.toolTip = "Hide the pointer while it's locked, showing a brief crosshair where taps or clicks land. Meant for touch screens; remembered for this lock screen only."
        menu.addItem(hide)

        let adjust = item("Touchscreen Adjust", #selector(touchAdjustClicked))
        adjust.state = touchAdjust(on: lockScreen) ? .on : .off
        adjust.isEnabled = canLock
        adjust.toolTip = "macOS sometimes sends a touch screen's taps to the main display. This moves them onto the lock screen, at the matching spot. On by default when a USB touch screen is connected."
        menu.addItem(adjust)

        let touch = item("Smart Touchscreen Mode", #selector(smartTouchClicked))
        touch.state = isEnabled(Self.smartTouchKey, on: lockScreen) ? .on : .off
        touch.isEnabled = canLock
        touch.toolTip = "While unlocked, a tap on the lock screen clicks what's under the finger in one go, then the pointer and keyboard focus return to where they were. Lets someone use the touch screen while you keep working."
        menu.addItem(touch)

        let dock = item("Keep Dock Off Lock Screen", #selector(keepDockOffClicked))
        dock.state = keepDockOff ? .on : .off
        dock.toolTip = "While locked, keep the pointer off the lock screen's bottom edge, so the Dock can't be pulled onto it."
        menu.addItem(dock)

        let menuBar = item("Keep Menu Bar Hidden on Lock Screen", #selector(keepMenuBarHiddenClicked))
        menuBar.state = keepMenuBarHidden ? .on : .off
        menuBar.toolTip = "While locked, keep the pointer off the lock screen's top edge, so a hidden menu bar (in full-screen apps) doesn't slide down."
        menu.addItem(menuBar)

        let context = item("Block Right-Click and Extra Buttons While Locked", #selector(blockExtraButtonsClicked))
        context.state = blockExtraButtons ? .on : .off
        context.toolTip = "While locked, ignore right-clicks and the middle and back/forward buttons, so the mouse can't open context menus or navigate the browser. Ctrl+click still works."
        menu.addItem(context)

        menu.addItem(.separator())
        let login = item("Start at Login", #selector(startAtLoginClicked))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.toolTip = "Start MouseLock automatically when you log in."
        menu.addItem(login)
        let quit = item("Quit MouseLock", #selector(quitClicked))
        quit.toolTip = "Quit MouseLock. Any lock is released."
        menu.addItem(quit)

        // While locked the pointer is on the lock screen, so any menu click
        // comes from there. Refuse everything (Quit would release the lock,
        // options could undo it): only the keyboard shortcut unlocks.
        if locker.isLocked {
            for item in menu.items { item.isEnabled = false }
            let note = NSMenuItem(title: "Locked: unlock with the keyboard shortcut", action: nil, keyEquivalent: "")
            note.isEnabled = false
            note.toolTip = "So that the mouse alone can't release the lock, the menu is disabled while locked."
            menu.insertItem(note, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func lockScreenClicked(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        lockScreen = number.uint32Value
        chosenLockScreenUUID = displayUUID(number.uint32Value)
        // Switching screens while locked moves the lock along.
        if locker.isLocked { lock() }
        updateState()
    }

    @objc func toggleClicked() { toggle() }

    @objc func keepDockOffClicked() {
        keepDockOff.toggle()
        locker.avoidBottomEdge = keepDockOff
    }

    @objc func keepMenuBarHiddenClicked() {
        keepMenuBarHidden.toggle()
        locker.avoidTopEdge = keepMenuBarHidden
    }

    @objc func blockExtraButtonsClicked() {
        blockExtraButtons.toggle()
        locker.blockExtraButtons = blockExtraButtons
    }

    @objc func hidePointerClicked() {
        toggle(Self.hidePointerKey, on: lockScreen)
        updateState()
    }

    @objc func touchAdjustClicked() {
        guard let lockScreen, let uuid = displayUUID(lockScreen) else { return }
        var choices = UserDefaults.standard.dictionary(forKey: Self.touchAdjustKey) as? [String: Bool] ?? [:]
        choices[uuid] = !touchAdjust(on: lockScreen)
        UserDefaults.standard.set(choices, forKey: Self.touchAdjustKey)
        updateState()
    }

    @objc func smartTouchClicked() {
        toggle(Self.smartTouchKey, on: lockScreen)
        updateState()
    }

    @objc func keepAwakeClicked() {
        keepAwakeManually.toggle()
        updateState()
    }

    @objc func startAtLoginClicked() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc func quitClicked() { NSApp.terminate(nil) }

    /// Hotkey and menu: unlock if locked, otherwise lock to the lock screen.
    func toggle() {
        if locker.isLocked {
            locker.unlock()
        } else {
            lock()
        }
    }

    /// Locking to the only screen would do nothing, so it needs two.
    /// (An existing lock stays on if a screen goes away, e.g. with the lid
    /// closed, as long as the lock screen itself is still there.)
    var canLock: Bool { Display.all().count > 1 }

    private func lock() {
        guard canLock, let lockScreen, locker.lock(to: lockScreen) else {
            // Only one screen, or no Accessibility permission yet (macOS has
            // shown, or will show, the prompt).
            NSSound.beep()
            return
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
