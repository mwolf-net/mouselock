import Foundation
import IOKit.pwr_mgt

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
