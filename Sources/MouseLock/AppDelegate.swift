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
    /// Touch-screen mode: the screens (by UUID) on which the pointer is hidden
    /// while locked. Per screen, so it's off for any screen not seen before.
    var hidePointerScreens: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "hidePointerScreens") ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: "hidePointerScreens") }
    }

    func hidesPointer(on display: CGDirectDisplayID?) -> Bool {
        guard let display, let uuid = displayUUID(display) else { return false }
        return hidePointerScreens.contains(uuid)
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
        pointerHider.set(hidesPointer(on: locker.lockedDisplay))

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
        menu.addItem(header)
        for display in displays {
            let title = display.name + (display.isBuiltin ? " (built-in)" : "")
            let entry = item(title, #selector(lockScreenClicked(_:)))
            entry.representedObject = NSNumber(value: display.id)
            entry.state = display.id == lockScreen ? .on : .off
            entry.indentationLevel = 1
            entry.isEnabled = canLock
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
        menu.addItem(toggleItem)

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

        let lockScreenName = displays.first { $0.id == lockScreen }?.name ?? "Lock Screen"
        let hide = item("Hide Pointer on \(lockScreenName)", #selector(hidePointerClicked))
        hide.state = hidesPointer(on: lockScreen) ? .on : .off
        hide.isEnabled = lockScreen != nil
        menu.addItem(hide)

        let dock = item("Keep Dock Off Lock Screen", #selector(keepDockOffClicked))
        dock.state = keepDockOff ? .on : .off
        menu.addItem(dock)

        let menuBar = item("Keep Menu Bar Hidden on Lock Screen", #selector(keepMenuBarHiddenClicked))
        menuBar.state = keepMenuBarHidden ? .on : .off
        menu.addItem(menuBar)

        let context = item("Block Right-Click and Extra Buttons While Locked", #selector(blockExtraButtonsClicked))
        context.state = blockExtraButtons ? .on : .off
        menu.addItem(context)

        menu.addItem(.separator())
        let login = item("Start at Login", #selector(startAtLoginClicked))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Quit MouseLock", #selector(quitClicked)))

        // While locked the pointer is on the lock screen, so any menu click
        // comes from there. Refuse everything (Quit would release the lock,
        // options could undo it): only the keyboard shortcut unlocks.
        if locker.isLocked {
            for item in menu.items { item.isEnabled = false }
            let note = NSMenuItem(title: "Locked: unlock with the keyboard shortcut", action: nil, keyEquivalent: "")
            note.isEnabled = false
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
        guard let lockScreen, let uuid = displayUUID(lockScreen) else { return }
        hidePointerScreens.formSymmetricDifference([uuid])
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
