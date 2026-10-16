// MouseLock: a menu bar app that confines the mouse pointer to one display.
//
// The lock is an event tap on mouse-move/drag events: whenever the pointer
// would leave the chosen display, it is clamped back to the display's edge.
// A global hotkey (Carbon RegisterEventHotKey, no extra permission needed)
// toggles the lock.

import AppKit

// Only one instance: a second one couldn't get the hotkey, and two locks
// to different screens would fight over the pointer.
let me = NSRunningApplication.current
if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    .contains(where: { $0 != me }) {
    FileHandle.standardError.write("MouseLock is already running.\n".data(using: .utf8)!)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
