import CoreGraphics

/// Hides the pointer system-wide (see PrivateAPI.swift).
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
