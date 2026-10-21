import Foundation
import IOKit.ps
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

extension StayAwake {
    /// What idleness will lead to first, as in "display off after 10 min",
    /// or nil if the display stays on (this app or another keeps it awake,
    /// or the settings say never). With the lid closed on battery, the Mac
    /// sleeps regardless, which the description says.
    static func firstIdleEvent() -> String? {
        let source = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String?
        let settings = source.flatMap { (IOPMCopyActivePMPreferences()?.takeRetainedValue() as? [String: Any])?[$0] }
            as? [String: Any] ?? [:]
        var events: [(minutes: Int, what: String, note: String)] = []

        if !displayKeptAwake() {
            // Unset means the macOS default of 20 minutes.
            let screenSaver = CFPreferencesCopyValue("idleTime" as CFString, "com.apple.screensaver" as CFString,
                                                     kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
                as? Int ?? 1200
            if screenSaver > 0 { events.append(((screenSaver + 59) / 60, "screen saver", "")) }
            if let display = settings["Display Sleep Timer"] as? Int, display > 0 {
                events.append((display, "display off", ""))
            }
        }
        if source == kIOPMBatteryPowerKey, lidClosed() {
            let sleep = settings["System Sleep Timer"] as? Int ?? 0
            events.append((sleep > 0 ? sleep : 1, "sleeps", ", clamshell"))
        }
        return events.min { $0.minutes < $1.minutes }.map { "\($0.what) after \($0.minutes) min\($0.note)" }
    }

    /// Whether some assertion (this app's or another's, such as a playing
    /// video) stops the display sleeping when idle.
    private static func displayKeptAwake() -> Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let counts = status?.takeRetainedValue() as? [String: Int] else { return false }
        return (counts[kIOPMAssertionTypePreventUserIdleDisplaySleep] ?? 0) > 0
    }

    private static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, nil, 0)?
            .takeRetainedValue() as? Bool ?? false
    }
}
