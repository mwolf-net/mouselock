import AppKit
import Carbon.HIToolbox
import ServiceManagement

// Hotkey that toggles the lock: Ctrl+Option+Cmd+L.
let hotKeyCode = UInt32(kVK_ANSI_L)
let hotKeyModifiers = UInt32(controlKey | optionKey | cmdKey)
// The same shortcut, for display in the menu.
let hotKeyEquivalent = "l"
let hotKeyEquivalentModifiers: NSEvent.ModifierFlags = [.control, .option, .command]
// Hotkey that toggles Smart Touchscreen Mode: Ctrl+Option+Cmd+S.
let smartTouchHotKeyCode = UInt32(kVK_ANSI_S)
let smartTouchHotKeyEquivalent = "s"
// Hotkey that toggles the window grid: Ctrl+Option+Cmd+W.
let windowGridHotKeyCode = UInt32(kVK_ANSI_W)
let windowGridHotKeyEquivalent = "w"
// Hotkey that undoes the last window layout change: Ctrl+Option+Cmd+Z.
let undoLayoutHotKeyCode = UInt32(kVK_ANSI_Z)
let undoLayoutHotKeyEquivalent = "z"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let locker = Locker()
    let stayAwake = StayAwake()
    /// Stay awake even while unlocked (menu toggle).
    var keepAwakeManually = false
    let pointerHider = PointerHider()
    let clickMarker = ClickMarker()
    let smartTouch = SmartTouch()
    let edgeMatcher = EdgeMatcher()
    let windowGrid = WindowGrid()
    let windowRestorer = WindowRestorer()
    let touchInput = TouchInput()
    let toast = Toast()

    // Touch-screen settings are stored per screen (as a set of display UUIDs
    // per key), so they're off for any screen not seen before.
    static let hidePointerKey = "hidePointerScreens"
    static let smartTouchKey = "smartTouchScreens"

    func isEnabled(_ key: String, on display: CGDirectDisplayID?) -> Bool {
        guard let display, let uuid = displayUUID(display) else { return false }
        return UserDefaults.standard.stringArray(forKey: key)?.contains(uuid) ?? false
    }

    // Touchscreen Adjust and Touch Drag Scrolls: on by default when a USB
    // touch screen is connected, unless the user picked on or off for this
    // screen (stored as display UUID -> Bool per key).
    static let touchAdjustKey = "touchscreenAdjust"
    static let dragScrollsKey = "touchDragScrolls"
    /// Touch Drag Scrolls used to be off by default and stored as a
    /// set of display UUIDs where it was turned on.
    static let oldDragToScrollKey = "dragToScrollScreens"

    func touchDefault(_ key: String, on display: CGDirectDisplayID?) -> Bool {
        if let display, let uuid = displayUUID(display),
           let choices = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool],
           let choice = choices[uuid] {
            return choice
        }
        if key == Self.dragScrollsKey, isEnabled(Self.oldDragToScrollKey, on: display) {
            return true
        }
        return TouchInput.touchScreenConnected()
    }

    func toggleTouchDefault(_ key: String, on display: CGDirectDisplayID?) {
        guard let display, let uuid = displayUUID(display) else { return }
        var choices = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        choices[uuid] = !touchDefault(key, on: display)
        UserDefaults.standard.set(choices, forKey: key)
    }

    func touchAdjust(on display: CGDirectDisplayID?) -> Bool {
        touchDefault(Self.touchAdjustKey, on: display)
    }

    func dragScrolls(on display: CGDirectDisplayID?) -> Bool {
        touchDefault(Self.dragScrollsKey, on: display)
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
    /// Window Grid (menu toggle and hotkey, remembered, off by default).
    var windowGridOn: Bool {
        get { UserDefaults.standard.bool(forKey: "windowGrid") }
        set { UserDefaults.standard.set(newValue, forKey: "windowGrid") }
    }
    /// Wrap Pointer Around (menu toggle, remembered, off by default).
    var wrapPointer: Bool {
        get { UserDefaults.standard.bool(forKey: "wrapPointer") }
        set { UserDefaults.standard.set(newValue, forKey: "wrapPointer") }
    }
    /// Match Screen Edges (menu toggle, remembered, off by default).
    var matchScreenEdges: Bool {
        get { UserDefaults.standard.bool(forKey: "matchScreenEdges") }
        set { UserDefaults.standard.set(newValue, forKey: "matchScreenEdges") }
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

    /// Smart Touchscreen Mode (menu toggle and hotkey, remembered). It used
    /// to be on per screen: then it's on if it was on for any.
    var smartTouchOn: Bool {
        get {
            UserDefaults.standard.object(forKey: "smartTouch") as? Bool
                ?? !(UserDefaults.standard.stringArray(forKey: Self.smartTouchKey) ?? []).isEmpty
        }
        set { UserDefaults.standard.set(newValue, forKey: "smartTouch") }
    }

    /// Touch Drag Scrolls (menu toggle, remembered). It used to be per screen:
    /// then what it was for the touch screen (on by default with a USB touch
    /// screen connected).
    var dragScrollsOn: Bool {
        get { UserDefaults.standard.object(forKey: "touchDragScrollsOn") as? Bool ?? dragScrolls(on: touchScreen) }
        set { UserDefaults.standard.set(newValue, forKey: "touchDragScrollsOn") }
    }

    /// The touch screen picked in the menu, by UUID, or `noTouchScreen`.
    /// Remembered.
    var chosenTouchScreenUUID: String? {
        get { UserDefaults.standard.string(forKey: "touchScreenUUID") }
        set { UserDefaults.standard.set(newValue, forKey: "touchScreenUUID") }
    }

    static let noTouchScreen = "none"

    /// The touch screen, for Touchscreen Adjust (where touches belong): with
    /// one screen, that one; else the one picked in the menu (or none); else
    /// none if no USB touch screen is connected; else one that
    /// had Smart Touchscreen Mode on (when that was per screen); else the lock
    /// screen picked in the menu (where the touch options used to apply);
    /// else the lock screen's default. (Which display a USB touch screen is
    /// can't be told: its touch part is a separate USB device.)
    var touchScreen: CGDirectDisplayID? {
        let displays = Display.all()
        let byUUID = { (uuid: String?) in displays.first { uuid != nil && displayUUID($0.id) == uuid }?.id }
        if displays.count == 1 { return displays[0].id }
        if chosenTouchScreenUUID == Self.noTouchScreen { return nil }
        if let chosen = byUUID(chosenTouchScreenUUID) { return chosen }
        guard TouchInput.touchScreenConnected() else { return nil }
        return displays.first { isEnabled(Self.smartTouchKey, on: $0.id) }?.id
            ?? byUUID(chosenLockScreenUUID)
            ?? defaultLockScreen()
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
        windowRestorer.snap = WindowGrid.snappedToGrid
        windowRestorer.notify = { [weak self] message in self?.toast.show(message, for: 5) }
        locker.onClick = { [weak self] point, isPress in
            guard let self else { return }
            reassertHiddenPointer()
            if isPress && pointerHider.isHidden { clickMarker.show(at: point) }
        }
        updateState()
        registerHotKey()
        checkAccessibilityPermission()
        watchForPermissionLoss()
        // Started with the window grid on (say at login): arrange the windows
        // once they're likely there.
        if windowGridOn {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, windowGridOn else { return }
                windowGrid.arrangeAll()
            }
        }
        smartTouch.isTouchEvent = { [touchInput] event in touchInput.isTouch(event) }
        edgeMatcher.isTouchEvent = { [touchInput] event in touchInput.isTouch(event) }
        // Smart touch hides the pointer while it's on the touch screen.
        smartTouch.onPointerFromTouchChanged = { [weak self] in self?.updateState() }
        // In smart touch mode, a scroll also sends the pointer back.
        touchInput.onScrollEnded = { [weak self] in self?.smartTouch.touchEnded() }
        touchInput.observeTouchScreens { [weak self] in
            if debugLogging {
                FileHandle.standardError.write("touch screens changed; connected: \(TouchInput.touchScreenConnected())\n".data(using: .utf8)!)
            }
            self?.updateState()
        }
        if debugLogging {
            FileHandle.standardError.write("touch screen connected: \(TouchInput.touchScreenConnected())\n".data(using: .utf8)!)
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.locker.refresh()
            self?.edgeMatcher.refresh()
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
        StuckButtons.releaseAll()
    }

    func updateState() {
        stayAwake.set(locker.isLocked || keepAwakeManually)
        pointerHider.set(isEnabled(Self.hidePointerKey, on: locker.lockedDisplay) || smartTouch.pointerFromTouch)
        // A touch screen's input may land on another screen; move it to the
        // touch screen.
        let touchScreen = self.touchScreen
        touchInput.touchScreen = touchScreen
        touchInput.remap = touchAdjust(on: touchScreen)
        touchInput.dragToScroll = dragScrollsOn
        // The touch screen's two-finger tap is a right-click: block it like
        // other right-clicks, both while locked and in smart touch mode.
        touchInput.blockRightClick = blockExtraButtons
            && (locker.isLocked || smartTouchOn)
        // Smart touch only applies while unlocked: when locked, everyone is
        // on the lock screen anyway.
        smartTouch.enabled = smartTouchOn && !locker.isLocked
        // Locked, the pointer stays on one screen anyway.
        edgeMatcher.enabled = matchScreenEdges && !locker.isLocked
        edgeMatcher.wrap = wrapPointer && !locker.isLocked
        windowGrid.enabled = windowGridOn
        windowRestorer.enabled = windowGridOn

        let symbol = !EventTaps.lastKnown ? "exclamationmark.triangle"
            : locker.isLocked ? "lock.fill"
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
        if !EventTaps.lastKnown {
            let permission = item("Accessibility Permission Needed\u{2026}", #selector(accessibilityClicked))
            permission.toolTip = "MouseLock needs Accessibility permission to see and adjust mouse and touch input; without it, locking and the touch screen options don't work. Opens System Settings."
            menu.addItem(permission)
            menu.addItem(.separator())
        }
        let displays = Display.all()

        // Window manager.
        let grid = item("Window Grid", #selector(windowGridClicked))
        grid.state = windowGridOn ? .on : .off
        grid.keyEquivalent = windowGridHotKeyEquivalent
        grid.keyEquivalentModifierMask = hotKeyEquivalentModifiers
        grid.toolTip = "Divides each screen into roughly square cells, as many as chosen under Window Grid Size. A window you resize or move snaps to the nearest cell edges, with an outline showing where while you drag. Turning it on also snaps all windows on screen to the cells, moving and resizing each as little as possible. Windows against a dragged edge follow it; windows you drag onto make room. Hold Control while dragging to leave other windows alone, or press Esc to put the window back. Windows that made room go back if you pick the window up again within 5 seconds and move it out of their way. New windows go into free space at the size they want (or as much as fits), or else open small on top."
        menu.addItem(grid)
        let undo = item("Undo Window Layout Change", #selector(undoLayoutClicked))
        undo.keyEquivalent = undoLayoutHotKeyEquivalent
        undo.keyEquivalentModifierMask = hotKeyEquivalentModifiers
        undo.isEnabled = windowGrid.canUndo
        undo.toolTip = "Puts the windows of the last window drag (including the ones that made room) or of arranging all back where they were. Again for the one before, and so on."
        menu.addItem(undo)
        // Sizes as each screen's columns × rows, main screen first.
        let sizes = NSMenuItem(title: "Window Grid Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        let screens = WindowGrid.usableScreens()
        for cells in WindowGrid.sizeChoices {
            let title = screens.map { screen in
                let (columns, rows) = WindowGrid.dimensions(of: screen.area, cells: cells)
                return "\(columns)×\(rows) on \(screen.name)"
            }.joined(separator: "  ·  ")
            let entry = item(title, #selector(gridSizeClicked(_:)))
            entry.representedObject = cells
            entry.state = cells == WindowGrid.cellsAlongShortSide ? .on : .off
            sizeMenu.addItem(entry)
        }
        sizes.submenu = sizeMenu
        menu.addItem(sizes)

        menu.addItem(.separator())
        // The pointer between screens.
        if displays.count > 1 {
            let edges = item("Match Screen Edges", #selector(matchScreenEdgesClicked))
            edges.state = matchScreenEdges ? .on : .off
            edges.toolTip = "When the pointer crosses between screens side by side, it lands at the same fraction of the height on the other screen, as if their corners touched. Helps when a Retina screen sits next to a lower resolution one of about the same size."
            menu.addItem(edges)
        }
        let wrap = item("Wrap Pointer Around", #selector(wrapPointerClicked))
        wrap.state = wrapPointer ? .on : .off
        wrap.toolTip = "Pushing the pointer off the right side of the rightmost screen brings it in on the left of the leftmost one, and the other way round, as if the screens were on a cylinder. Also while dragging a window or a file, but not while resizing a window by its edge, nor while locked."
        menu.addItem(wrap)

        menu.addItem(.separator())
        // Shortcuts for what System Settings can do too.
        if let (_, others) = ScreenArrangement.primaryAndOthers(of: displays) {
            for screen in others {
                let position = NSMenuItem(title: "Position \(screen.name)", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for option in ScreenArrangement.options(for: screen.id, among: displays) {
                    let entry = item(option.title, #selector(positionClicked(_:)))
                    entry.representedObject = PositionChoice(screen: screen.id, placement: option.placement)
                    entry.state = option.isCurrent ? .on : .off
                    submenu.addItem(entry)
                }
                position.submenu = submenu
                menu.addItem(position)
            }
        }
        if locker.isLocked {
            let awake = NSMenuItem(title: "Keeping Display Awake (while locked)", action: nil, keyEquivalent: "")
            awake.state = .on
            awake.isEnabled = false
            awake.toolTip = "While locked, the display never sleeps and the screen saver and idle password lock don't start."
            menu.addItem(awake)
        } else {
            // Say what happens when idle, or that the display stays on
            // anyway (settings, or another app keeping it awake).
            // Unchecked, what happens is what you'd keep awake from: "else".
            let firstEvent = StayAwake.firstIdleEvent()
            let note = keepAwakeManually ? firstEvent : firstEvent.map { "else: \($0)" } ?? "display stays on"
            let awake = item("Keep Display Awake" + (note.map { " (\($0))" } ?? ""),
                             #selector(keepAwakeClicked))
            awake.state = keepAwakeManually ? .on : .off
            awake.toolTip = "Keep the display awake (no screen saver, display sleep or idle password lock) without locking the pointer. Always on while locked. Resets when MouseLock restarts. Also shows what happens first when the Mac is left alone, or that the display stays on anyway (because of your settings, or another app such as a video playing). Doesn't stop a laptop sleeping when its lid is closed on battery power."
            menu.addItem(awake)
        }


        menu.addItem(.separator())
        let heading = NSMenuItem(title: "Touchscreen", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        let touch = item("Smart Touchscreen Mode", #selector(smartTouchClicked))
        touch.state = smartTouchOn ? .on : .off
        touch.keyEquivalent = smartTouchHotKeyEquivalent
        touch.keyEquivalentModifierMask = hotKeyEquivalentModifiers
        touch.toolTip = "While unlocked, a tap clicks what's under the finger in one go, then the pointer and keyboard focus return to where they were, and the pointer stays hidden where the finger was until you use the mouse. Lets someone use a touch screen while you keep working, on a separate touch screen or on a single shared one, and lets you use mouse and touch interchangeably. A tap in a password field keeps the keyboard, so a PIN can be typed."
        touch.indentationLevel = 1
        menu.addItem(touch)

        let scroll = item("Touch Drag Scrolls", #selector(dragToScrollClicked))
        scroll.state = dragScrollsOn ? .on : .off
        scroll.toolTip = "Dragging a finger scrolls instead of selecting text. A tap still clicks; to select or drag things, hold the finger still for a moment first. On by default when a USB touch screen is connected."
        scroll.indentationLevel = 1
        menu.addItem(scroll)

        let adjust = item("Touchscreen Adjust", #selector(touchAdjustClicked))
        adjust.state = touchAdjust(on: touchScreen) ? .on : .off
        adjust.isEnabled = canLock && touchScreen != nil
        adjust.toolTip = "Puts touches where the finger is: macOS sometimes sends a touch screen's taps to the main display, and doesn't rotate them along with a rotated screen. Also makes two-finger scrolling scroll where the fingers are, and ignores pinch (which the screen sends as screen-zoom key presses). On by default when a USB touch screen is connected."
        adjust.indentationLevel = 1
        menu.addItem(adjust)
        // Which screen is the touch screen, as a submenu: for Touchscreen
        // Adjust. With one screen there's nothing to choose.
        if displays.count > 1 {
            let touchScreen = self.touchScreen
            let touchName = displays.first { $0.id == touchScreen }?.name ?? "None"
            let touchHeader = NSMenuItem(title: "Touch Screen: \(touchName)", action: nil, keyEquivalent: "")
            let touchMenu = NSMenu()
            touchMenu.autoenablesItems = false
            let none = item("None", #selector(touchScreenClicked(_:)))
            none.state = touchScreen == nil ? .on : .off
            none.toolTip = "None of the screens is a touch screen. The default when no USB touch screen is connected."
            touchMenu.addItem(none)
            touchMenu.addItem(.separator())
            for display in displays {
                let title = display.name + (display.isBuiltin ? " (built-in)" : "")
                let entry = item(title, #selector(touchScreenClicked(_:)))
                entry.representedObject = NSNumber(value: display.id)
                entry.state = display.id == touchScreen ? .on : .off
                entry.toolTip = "This is the touch screen. Your choice is remembered whenever this screen is connected."
                touchMenu.addItem(entry)
            }
            touchHeader.submenu = touchMenu
            touchHeader.toolTip = "Which screen is the touch screen: Touchscreen Adjust moves touches there. MouseLock can't tell by itself, since a touch screen's touch part is a separate USB device."
            touchHeader.indentationLevel = 1
            menu.addItem(touchHeader)
        }


        menu.addItem(.separator())
        let lockName = displays.first { $0.id == (locker.lockedDisplay ?? lockScreen) }?.name
        let toggleTitle = locker.isLocked ? "Unlock Pointer" + (lockName.map { " (from \($0))" } ?? "")
            : !canLock ? "Lock Pointer (needs a second screen)"
            : "Lock Pointer" + (lockName.map { " to \($0)" } ?? "")
        let toggleItem = item(toggleTitle, #selector(toggleClicked))
        toggleItem.keyEquivalent = hotKeyEquivalent
        toggleItem.keyEquivalentModifierMask = hotKeyEquivalentModifiers
        toggleItem.isEnabled = locker.isLocked || canLock
        toggleItem.toolTip = locker.isLocked
            ? "Release the pointer and put it back where it was before locking."
            : "Move the pointer to the lock screen and keep it there: moving the mouse can't take it off. Only the keyboard shortcut unlocks."
        menu.addItem(toggleItem)
        let lockOptions = NSMenuItem(title: "Lock Options", action: nil, keyEquivalent: "")
        let lockMenu = NSMenu()
        lockMenu.autoenablesItems = false
        let header = NSMenuItem(title: "Lock Screen", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.toolTip = "The screen the pointer gets locked to. Usually the second screen for customers or guests; if it's a touch screen, the touch options below apply to it."
        lockMenu.addItem(header)
        for display in displays {
            let title = display.name + (display.isBuiltin ? " (built-in)" : "")
            let entry = item(title, #selector(lockScreenClicked(_:)))
            entry.representedObject = NSNumber(value: display.id)
            entry.state = display.id == lockScreen ? .on : .off
            entry.indentationLevel = 1
            entry.isEnabled = canLock
            entry.toolTip = "Use this screen as the lock screen. Your choice is remembered whenever this screen is connected."
            lockMenu.addItem(entry)
        }

        lockMenu.addItem(.separator())
        // Remembered per screen (see isEnabled(_:on:)), without saying so.
        let hide = item("Hide Pointer When Locked", #selector(hidePointerClicked))
        hide.state = isEnabled(Self.hidePointerKey, on: lockScreen) ? .on : .off
        hide.isEnabled = lockScreen != nil
        hide.toolTip = "Hide the pointer while it's locked, showing a brief crosshair where taps or clicks land. Meant for touch screens; remembered for this lock screen only."
        lockMenu.addItem(hide)

        let dock = item("Keep Dock Off Lock Screen", #selector(keepDockOffClicked))
        dock.state = keepDockOff ? .on : .off
        dock.toolTip = "While locked, keep the pointer off the lock screen's bottom edge, so the Dock can't be pulled onto it."
        lockMenu.addItem(dock)

        let menuBar = item("Keep Menu Bar Hidden on Lock Screen", #selector(keepMenuBarHiddenClicked))
        menuBar.state = keepMenuBarHidden ? .on : .off
        menuBar.toolTip = "While locked, keep the pointer off the lock screen's top edge, so a hidden menu bar (in full-screen apps) doesn't slide down."
        lockMenu.addItem(menuBar)

        let context = item("Block Right-Click and Extra Buttons While Locked", #selector(blockExtraButtonsClicked))
        context.state = blockExtraButtons ? .on : .off
        context.toolTip = "While locked, ignore right-clicks and the middle and back/forward buttons, so the mouse can't open context menus or navigate the browser. Ctrl+click still works. Also ignores a touch screen's two-finger tap (a right-click) in Smart Touchscreen Mode."
        lockMenu.addItem(context)

        lockOptions.submenu = lockMenu
        menu.addItem(lockOptions)

        menu.addItem(.separator())
        let login = item("Start at Login", #selector(startAtLoginClicked))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.toolTip = "Start MouseLock automatically when you log in."
        menu.addItem(login)
        let about = item("About MouseLock…", #selector(aboutClicked))
        about.toolTip = "What MouseLock does, and what each option is for."
        menu.addItem(about)
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

    @objc func touchScreenClicked(_ sender: NSMenuItem) {
        if let number = sender.representedObject as? NSNumber {
            chosenTouchScreenUUID = displayUUID(number.uint32Value)
        } else {
            chosenTouchScreenUUID = Self.noTouchScreen
        }
        updateState()
    }

    @objc func toggleClicked() { toggle() }

    @objc func windowGridClicked() { toggleWindowGrid() }

    @objc func gridSizeClicked(_ sender: NSMenuItem) {
        guard let cells = sender.representedObject as? Int else { return }
        WindowGrid.cellsAlongShortSide = cells
        if windowGridOn { windowGrid.arrangeAll() }
    }

    /// From the menu or the hotkey. Turning it on arranges the windows.
    func toggleWindowGrid() {
        windowGridOn.toggle()
        updateState()
        if windowGridOn { windowGrid.arrangeAll() }
    }

    @objc func undoLayoutClicked() { undoLayout() }

    /// From the menu or the hotkey.
    func undoLayout() {
        if !windowGrid.undo() { toast.show("Nothing to undo") }
    }

    @objc func wrapPointerClicked() {
        wrapPointer.toggle()
        updateState()
    }

    @objc func matchScreenEdgesClicked() {
        matchScreenEdges.toggle()
        updateState()
    }

    struct PositionChoice {
        let screen: CGDirectDisplayID
        let placement: ScreenArrangement.Placement
    }

    @objc func positionClicked(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? PositionChoice else { return }
        ScreenArrangement.place(choice.screen, choice.placement, among: Display.all().map(\.id))
    }

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
        updateState()
    }

    @objc func hidePointerClicked() {
        toggle(Self.hidePointerKey, on: lockScreen)
        updateState()
    }

    @objc func touchAdjustClicked() {
        toggleTouchDefault(Self.touchAdjustKey, on: touchScreen)
        updateState()
    }

    @objc func smartTouchClicked() { toggleSmartTouch() }

    /// From the menu or the hotkey.
    func toggleSmartTouch() {
        smartTouchOn.toggle()
        updateState()
    }

    /// The hotkey: as the menu, and say what it did, as there's no menu to see.
    func smartTouchHotKey() {
        toggleSmartTouch()
        toast.show("Smart Touchscreen Mode " + (smartTouchOn ? "On" : "Off"))
    }

    @objc func dragToScrollClicked() {
        dragScrollsOn.toggle()
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

    let aboutWindow = AboutWindow()

    @objc func aboutClicked() { aboutWindow.show() }

    // MARK: Accessibility permission

    private var permissionTimer: Timer?

    /// Without Accessibility permission none of the event taps work. Each new
    /// (ad-hoc signed) build counts as a new app to macOS, and an entry left
    /// over from the previous build looks enabled but doesn't apply. So on
    /// the first launch of a build without permission, remove that stale
    /// entry and ask again; then watch for the permission being granted.
    private func checkAccessibilityPermission() {
        guard !EventTaps.permitted else { return }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if UserDefaults.standard.string(forKey: "permissionResetForBuild") != build,
           let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.set(build, forKey: "permissionResetForBuild")
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", bundleID]
            try? reset.run()
            reset.waitUntilExit()
        }
        requestAccessibilityPermission()
        waitForPermission()
    }

    private func waitForPermission() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard EventTaps.permitted else { return }
            timer.invalidate()
            self?.permissionTimer = nil
            if debugLogging {
                FileHandle.standardError.write("accessibility permission granted; setting up event taps\n".data(using: .utf8)!)
            }
            // Now the event taps can be created.
            self?.updateState()
        }
    }

    /// Taking the permission away while the event taps exist freezes all
    /// input (see EventTaps), so remove them as soon as that happens. macOS
    /// announces changes to the Accessibility list; a timer catches any
    /// change it doesn't announce.
    private func watchForPermissionLoss() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The change can take a moment to apply.
            for delay in [0.0, 0.3, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.checkPermissionKept() }
            }
        }
        // In case a change isn't announced (say one made with tccutil, or by
        // a management profile). Each check starts a process, so only once a
        // minute: input may then be frozen for up to that long, rather than
        // until a restart. Also while a menu is open.
        RunLoop.main.add(Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkPermissionKept(announced: false)
        }, forMode: .common)
    }

    private func checkPermissionKept(announced: Bool = true) {
        guard !EventTaps.isEmpty, !EventTaps.permitted else { return }
        if debugLogging {
            FileHandle.standardError.write("accessibility permission lost; removing event taps\n".data(using: .utf8)!)
        }
        EventTaps.removeAll()
        StuckButtons.releaseAll()
        if locker.isLocked { locker.unlock() }
        // Recreate them once it's back.
        waitForPermission()
        if !announced { explainPermissionLoss() }
    }

    /// Mouse and keyboard may just have been frozen for a while: say why, so
    /// it doesn't look like MouseLock misbehaving.
    private func explainPermissionLoss() {
        let alert = NSAlert()
        alert.messageText = "MouseLock's Accessibility permission was turned off"
        alert.informativeText = """
            macOS took away MouseLock's permission without letting it know right away. \
            Until MouseLock noticed, the mouse and keyboard may not have responded \
            for up to a minute.

            MouseLock's features are paused. They come back by themselves when you \
            allow MouseLock again in System Settings > Privacy & Security > Accessibility.
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Accessibility Settings")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    private func requestAccessibilityPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    @objc func accessibilityClicked() {
        requestAccessibilityPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        if permissionTimer == nil { checkAccessibilityPermission() }
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
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if id.id == 2 {
                delegate.smartTouchHotKey()
            } else if id.id == 4 {
                delegate.undoLayout()
            } else if id.id == 3 {
                delegate.toggleWindowGrid()
                delegate.toast.show("Window Grid " + (delegate.windowGridOn ? "On" : "Off"))
            } else {
                delegate.toggle()
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)

        var ref: EventHotKeyRef?
        let signature = OSType(0x4D4C_434B) // 'MLCK'
        RegisterEventHotKey(hotKeyCode, hotKeyModifiers, EventHotKeyID(signature: signature, id: 1),
                            GetApplicationEventTarget(), 0, &ref)
        var smartTouchRef: EventHotKeyRef?
        RegisterEventHotKey(smartTouchHotKeyCode, hotKeyModifiers, EventHotKeyID(signature: signature, id: 2),
                            GetApplicationEventTarget(), 0, &smartTouchRef)
        var windowGridRef: EventHotKeyRef?
        RegisterEventHotKey(windowGridHotKeyCode, hotKeyModifiers, EventHotKeyID(signature: signature, id: 3),
                            GetApplicationEventTarget(), 0, &windowGridRef)
        var undoLayoutRef: EventHotKeyRef?
        RegisterEventHotKey(undoLayoutHotKeyCode, hotKeyModifiers, EventHotKeyID(signature: signature, id: 4),
                            GetApplicationEventTarget(), 0, &undoLayoutRef)
    }
}
