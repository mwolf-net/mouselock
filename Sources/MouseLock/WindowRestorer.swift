import AppKit

/// Looks after windows when a screen is disconnected and reconnected.
///
/// When a screen goes, macOS moves its windows to the remaining ones, and
/// with "Displays have separate Spaces" (the default) shows them in the
/// visible Space there, while the windows that were already there wait in
/// another Space. So bring those back, and say where the others went.
///
/// The moved windows are remembered with where they were on that screen;
/// when it comes back, each one still where macOS put it is moved back (as
/// macOS normally does itself). One moved since is left alone.
final class WindowRestorer {
    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            displaced = [:]
            enabled ? start() : stop()
        }
    }
    /// Snaps a restored window onto the screen's grid.
    var snap: ((CGRect) -> CGRect)?
    /// Shows a brief message.
    var notify: ((String) -> Void)?

    private struct Seen {
        let pid: pid_t
        let screen: String
        /// Relative to the screen's bounds.
        let offset: CGRect
        /// The screen's bounds then.
        let screenBounds: CGRect
    }

    private struct Displaced {
        let number: CGWindowID
        let pid: pid_t
        let offset: CGRect
        let screenSize: CGSize
        /// Where macOS put it, once it settled.
        var parked: CGRect?
    }

    /// Every window on screen, as of the last look.
    private var seen: [CGWindowID: Seen] = [:]
    /// Their order then, front to back.
    private var order: [CGWindowID] = []
    /// Screen names by UUID, for screens seen connected.
    private var names: [String: String] = [:]
    /// Per screen UUID, windows moved off it when it went.
    private var displaced: [String: [Displaced]] = [:]
    private var screens: Set<String> = []
    private var timer: Timer?
    /// While screens are being reconfigured, windows are on the move.
    private var reconfiguring = false
    private var settleWork: DispatchWorkItem?

    private func start() {
        screens = Self.currentScreens()
        look()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, !reconfiguring else { return }
            look()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        CGDisplayRegisterReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        CGDisplayRemoveReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
        seen = [:]
    }

    private static let callback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        let restorer = Unmanaged<WindowRestorer>.fromOpaque(userInfo!).takeUnretainedValue()
        DispatchQueue.main.async {
            if flags.contains(.beginConfigurationFlag) {
                restorer.willReconfigure()
            } else {
                restorer.didReconfigure()
            }
        }
    }

    private func willReconfigure() {
        guard enabled, !reconfiguring else { return }
        reconfiguring = true
        // Windows may already be on the move, so keep where they were last
        // seen (at most a few seconds ago); only add ones new since.
        let before = seen, beforeOrder = order
        look()
        seen.merge(before) { _, earlier in earlier }
        order = beforeOrder + order.filter { !beforeOrder.contains($0) }
    }

    /// Called for each display that changed; acts once they've all settled.
    private func didReconfigure() {
        guard enabled else { return }
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settled() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func settled() {
        reconfiguring = false
        let now = Self.currentScreens()
        let gone = screens.subtracting(now)
        let back = now.subtracting(screens)
        screens = now

        for screen in gone {
            let windows = seen.filter { $0.value.screen == screen }.map { number, window in
                Displaced(number: number, pid: window.pid, offset: window.offset,
                          screenSize: window.screenBounds.size)
            }
            guard !windows.isEmpty else { continue }
            log("screen \(screen) gone; remembering \(windows.count) windows")
            displaced[screen] = windows
        }
        let current = Dictionary(WindowGrid.windowList().map { ($0.number, $0.frame) }, uniquingKeysWith: { a, _ in a })
        // Note where macOS put the displaced windows.
        for screen in gone {
            displaced[screen] = displaced[screen]?.map { window in
                var window = window
                window.parked = current[window.number]
                return window
            }
        }
        if !gone.isEmpty { bringBackResidents(remaining: now, gone: gone) }
        for screen in back {
            guard let windows = displaced.removeValue(forKey: screen),
                  let display = Self.display(for: screen) else { continue }
            restore(windows, to: CGDisplayBounds(display), current: current)
        }
        look()
    }

    /// Switches back to the Space with the windows that were on the remaining
    /// screens, by making the app of the frontmost one frontmost (macOS then
    /// shows a Space with its windows). Preferably an app with no windows
    /// among the moved ones, which could take macOS to their Space instead.
    private func bringBackResidents(remaining: Set<String>, gone: Set<String>) {
        let moved = gone.flatMap { displaced[$0] ?? [] }
        guard !moved.isEmpty else { return }
        let movedApps = Set(moved.map(\.pid))
        let residents = order.compactMap { number in seen[number].map { (number, $0) } }
            .filter { remaining.contains($0.1.screen) }
        guard let (number, resident) = residents.first(where: { !movedApps.contains($0.1.pid) }) ?? residents.first
        else { return }
        log("switching back to the Space with window \(number)")
        let app = AXUIElementCreateApplication(resident.pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        let name = gone.compactMap { names[$0] }.first ?? "the disconnected screen"
        let count = moved.count == 1 ? "1 window" : "\(moved.count) windows"
        notify?("\(count) from \(name) moved to another Space. Use Mission Control to find them.")
    }

    private func restore(_ windows: [Displaced], to bounds: CGRect, current: [CGWindowID: CGRect]) {
        // Front to back: put the frontmost back last, so it ends up on top.
        for window in windows.reversed() {
            guard let parked = window.parked, let frame = current[window.number] else { continue }
            guard WindowGrid.sameFrame(frame, parked) else {
                log("window \(window.number) moved since; leaving it at \(frame)")
                continue
            }
            // The screen may have come back at another resolution.
            let scaleX = bounds.width / window.screenSize.width
            let scaleY = bounds.height / window.screenSize.height
            var target = CGRect(x: bounds.minX + window.offset.minX * scaleX,
                                y: bounds.minY + window.offset.minY * scaleY,
                                width: window.offset.width * scaleX, height: window.offset.height * scaleY)
            if let snap { target = snap(target) }
            guard let element = axWindow(pid: window.pid, frame: frame) else { continue }
            log("putting window \(window.number) back: \(frame) -> \(target)")
            setAXFrame(element, target)
        }
    }

    /// Notes which screen each window is on.
    private func look() {
        let bounds = Self.currentScreenBounds()
        for display in Display.all() {
            if let uuid = displayUUID(display.id) { names[uuid] = display.name }
        }
        var seen: [CGWindowID: Seen] = [:]
        var order: [CGWindowID] = []
        for window in WindowGrid.windowList() {
            let overlaps = bounds.map { ($0.uuid, $0.bounds, window.frame.intersection($0.bounds)) }
                .filter { !$0.2.isNull }
            guard let (uuid, screen, _) = overlaps.max(by: { $0.2.width * $0.2.height < $1.2.width * $1.2.height })
            else { continue }
            seen[window.number] = Seen(pid: window.pid, screen: uuid,
                                       offset: window.frame.offsetBy(dx: -screen.minX, dy: -screen.minY),
                                       screenBounds: screen)
            order.append(window.number)
        }
        self.seen = seen
        self.order = order
    }

    private static func currentScreenBounds() -> [(uuid: String, bounds: CGRect)] {
        Display.all().compactMap { display in
            displayUUID(display.id).map { ($0, CGDisplayBounds(display.id)) }
        }
    }

    private static func currentScreens() -> Set<String> {
        Set(currentScreenBounds().map(\.uuid))
    }

    private static func display(for uuid: String) -> CGDirectDisplayID? {
        Display.all().first { displayUUID($0.id) == uuid }?.id
    }

    private func log(_ message: String) {
        guard debugLogging else { return }
        FileHandle.standardError.write("window restore: \(message)\n".data(using: .utf8)!)
    }
}
