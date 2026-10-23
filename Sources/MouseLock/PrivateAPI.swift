// Undocumented CoreGraphics calls, gathered here so they're easy to audit.
// Each is optional: if a future macOS drops or ignores one, MouseLock keeps
// working, just without that refinement.

import ApplicationServices
import CoreGraphics

// Warping the pointer normally makes macOS ignore mouse input for ~0.25s,
// which swallows the start of a swipe right after a clamp. This call turns
// that off for the session; Swift marks it unavailable, but the symbol is
// still exported and works, so declare it by name.
@_silgen_name("CGSetLocalEventsSuppressionInterval")
func CGSetLocalEventsSuppressionIntervalCompat(_ seconds: CFTimeInterval) -> CGError

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

// Event field 87 holds the registry entry ID of the device (HID service)
// that sent the event. Not in the public CGEventField enum, but stable for
// years; TouchInput uses it to tell touch screen input from the mouse.
let senderIDField = CGEventField(rawValue: 87)!

// The power settings in effect (per power source: "AC Power", "Battery
// Power"), as `pmset -g` shows them; there's no public call to read them.
// Only used to describe in the menu when the display will sleep.
@_silgen_name("IOPMCopyActivePMPreferences")
func IOPMCopyActivePMPreferences() -> Unmanaged<CFDictionary>?

// The window number (as in the window list) of an Accessibility window
// element. Private, but long used by window managers; without it, windows
// are matched by their frame, which an app may still be changing.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ window: UnsafeMutablePointer<CGWindowID>) -> AXError
