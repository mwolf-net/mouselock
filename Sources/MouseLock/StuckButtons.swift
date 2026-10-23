import CoreGraphics
import Foundation

/// Guards against a mouse button left down. MouseLock posts presses itself
/// (touches held back to tell a tap from a drag, smart touch's replays); if
/// the matching release never comes (the touch screen unplugged mid-touch,
/// an event tap switched off by macOS at the wrong moment), macOS keeps the
/// button down and clicks stop working, even after MouseLock quits. So for a
/// press MouseLock posted: once no actual device has had the button down for
/// a couple of seconds while macOS still thinks it's down, post the release.
/// Presses posted by other software are left alone.
enum StuckButtons {
    /// Buttons MouseLock pressed and hasn't seen released, with when they
    /// were last actually held on a device.
    private static var outstanding: [CGMouseButton: Date] = [:]
    private static var timer: Timer?
    private static let grace: TimeInterval = 2

    /// Called for each mouse event MouseLock posts.
    static func posted(_ event: CGEvent) {
        switch event.type {
        case .leftMouseDown: outstanding[.left] = Date()
        case .rightMouseDown: outstanding[.right] = Date()
        case .leftMouseUp: outstanding[.left] = nil
        case .rightMouseUp: outstanding[.right] = nil
        default: return
        }
        if !outstanding.isEmpty, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in check(force: false) }
        }
    }

    /// Releases any of MouseLock's presses that no device holds (on quit).
    static func releaseAll() {
        check(force: true)
    }

    private static func check(force: Bool) {
        for (button, heldAt) in outstanding {
            if !CGEventSource.buttonState(.combinedSessionState, button: button) {
                outstanding[button] = nil
            } else if CGEventSource.buttonState(.hidSystemState, button: button) {
                outstanding[button] = Date()
            } else if force || Date().timeIntervalSince(heldAt) > grace {
                release(button)
            }
        }
        if outstanding.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Posts the release of `button` where the pointer is.
    static func release(_ button: CGMouseButton) {
        let type: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        guard let up = CGEvent(mouseEventSource: nil, mouseType: type,
                               mouseCursorPosition: pointerLocation(), mouseButton: button) else { return }
        if debugLogging {
            FileHandle.standardError.write("stuck \(button == .right ? "right" : "left") button: releasing\n"
                .data(using: .utf8)!)
        }
        outstanding[button] = nil
        // Marked like smart touch's replays, so MouseLock's own taps let it by.
        up.setIntegerValueField(.eventSourceUserData, value: SmartTouch.replayMarker)
        up.post(tap: .cghidEventTap)
    }
}
