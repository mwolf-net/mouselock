// Undocumented CoreGraphics calls, gathered here so they're easy to audit.
// Each is optional: if a future macOS drops or ignores one, MouseLock keeps
// working, just without that refinement.

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
