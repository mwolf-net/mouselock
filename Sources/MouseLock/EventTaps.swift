import AppKit

/// Every event tap MouseLock creates, so they can all be removed at once.
///
/// When Accessibility permission is taken away while an active tap exists,
/// macOS doesn't remove the tap: the WindowServer keeps routing events
/// through it but then drops every one ("Sender is prohibited from
/// synthesizing events"), freezing mouse and keyboard for the whole session,
/// login screen included. So the taps must go the moment permission does.
enum EventTaps {
    /// Whether taps may be created and their events go through. A process's
    /// own answer goes stale: once it's running (and more so once it has
    /// taps), AXIsProcessTrusted() and CGPreflightPostEventAccess() keep
    /// returning true after the permission is taken away. A freshly started
    /// process gets the current answer, so ask a copy of MouseLock (see
    /// `permissionCheckArgument`), which macOS treats as the same app.
    static var permitted: Bool {
        let check = Process()
        check.executableURL = Bundle.main.executableURL
        check.arguments = [permissionCheckArgument]
        let output = Pipe()
        check.standardOutput = output
        do { try check.run() } catch { return AXIsProcessTrusted() && CGPreflightPostEventAccess() }
        check.waitUntilExit()
        let answer = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        lastKnown = answer?.trimmingCharacters(in: .whitespacesAndNewlines) != "no"
        return lastKnown
    }

    /// The answer `permitted` last gave (about 80 ms to find out), for the menu.
    static private(set) var lastKnown = AXIsProcessTrusted() && CGPreflightPostEventAccess()

    /// Run with this argument, MouseLock prints whether it has the permission
    /// ("yes" or "no") and exits.
    static let permissionCheckArgument = "--check-permission"

    static func printPermission() {
        print(AXIsProcessTrusted() && CGPreflightPostEventAccess() ? "yes" : "no")
    }

    private static var taps: [CFMachPort] = []

    static var isEmpty: Bool { taps.isEmpty }

    static func add(_ tap: CFMachPort) {
        taps.append(tap)
    }

    /// Whether `tap` exists and hasn't been removed.
    static func isLive(_ tap: CFMachPort?) -> Bool {
        tap.map(CFMachPortIsValid) ?? false
    }

    static func removeAll() {
        for tap in taps {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        taps = []
    }
}
