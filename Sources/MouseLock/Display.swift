import AppKit

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

/// A display's UUID, which stays the same across reboots and reconnects.
func displayUUID(_ display: CGDirectDisplayID) -> String? {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
    return CFUUIDCreateString(nil, uuid) as String
}

func pointerLocation() -> CGPoint {
    // Global coordinates with the origin at the top-left of the main display,
    // the same space as CGDisplayBounds and event locations.
    CGEvent(source: nil)?.location ?? .zero
}
