import AppKit

/// Window Grid: each screen's usable area (without menu bar and Dock) is
/// divided into roughly square cells, 8 along its short side. While it's on,
/// a window that was resized has the edges that moved snapped to the nearest
/// grid lines; turning it on snaps the edges of every window.
final class WindowGrid {
    static let cellsAlongShortSide = 8

    var enabled = false {
        didSet { updateTap() }
    }

    private var tap: CFMachPort?
    /// The window under a press, and its frame then.
    private var pressed: (number: CGWindowID, pid: pid_t, frame: CGRect)?

    struct Grid {
        /// Vertical and horizontal lines, in global coordinates (top left
        /// origin), first and last on the area's edges.
        let xs: [CGFloat]
        let ys: [CGFloat]
    }

    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4)
        static let bottom = Edges(rawValue: 8)
        static let all: Edges = [.left, .right, .top, .bottom]
    }

    /// Snaps the edges of all windows on screen to the grid: each edge goes
    /// to the nearest line, which keeps both moving and resizing small.
    func arrangeAll() {
        let areas = Self.usableAreas()
        for window in Self.windowList() {
            guard let grid = Self.grid(for: window.frame, areas: areas) else { continue }
            let target = Self.snapped(window.frame, to: grid, edges: .all)
            guard target != window.frame, let element = axWindow(pid: window.pid, frame: window.frame),
                  Self.isResizable(element) else { continue }
            Self.fit(element, into: target, anchoring: [.left, .top])
        }
    }

    /// Gives `window` the frame `target`. An app may round the size (say to
    /// whole character cells in Terminal) or keep a minimum: if it comes out
    /// larger, ask again for less, so it ends up with a gap rather than
    /// overlapping its neighbours. It's then put against the `anchoring`
    /// edges of `target` (the others if not given).
    private static func fit(_ window: AXUIElement, into target: CGRect, anchoring: Edges) {
        setAXFrame(window, target)
        var requested = target.size
        for _ in 0..<3 {
            guard let actual = axFrame(window) else { return }
            let over = CGSize(width: max(0, actual.width - target.width), height: max(0, actual.height - target.height))
            guard over.width > 0.5 || over.height > 0.5 else { break }
            requested = CGSize(width: requested.width - over.width, height: requested.height - over.height)
            var size = requested
            guard let value = AXValueCreate(.cgSize, &size) else { return }
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
        guard let actual = axFrame(window) else { return }
        var origin = CGPoint(x: anchoring.contains(.right) && !anchoring.contains(.left)
                                ? target.maxX - actual.width : target.minX,
                             y: anchoring.contains(.bottom) && !anchoring.contains(.top)
                                ? target.maxY - actual.height : target.minY)
        guard origin != actual.origin, let value = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    // MARK: Snapping after a resize

    private func updateTap() {
        pressed = nil
        if !enabled {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            return
        }
        guard let tap = ensureTap() else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func ensureTap() -> CFMachPort? {
        if let tap { return tap }
        guard AXIsProcessTrusted() else { return nil }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let grid = Unmanaged<WindowGrid>.fromOpaque(refcon!).takeUnretainedValue()
            grid.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        // Listen only: the grid never changes or holds up a click.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        return tap
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if enabled, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            // Resize handles reach a few points outside the window.
            let point = event.location
            pressed = Self.windowList().first { $0.frame.insetBy(dx: -8, dy: -8).contains(point) }
                .map { ($0.number, $0.pid, $0.frame) }
        case .leftMouseUp:
            guard let pressed else { return }
            self.pressed = nil
            // Let the app finish the resize first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.snapIfResized(pressed)
            }
        default:
            break
        }
    }

    private func snapIfResized(_ pressed: (number: CGWindowID, pid: pid_t, frame: CGRect)) {
        guard enabled, let now = Self.frame(of: pressed.number) else { return }
        let before = pressed.frame
        guard abs(now.width - before.width) > 1 || abs(now.height - before.height) > 1 else { return }
        var moved: Edges = []
        if abs(now.minX - before.minX) > 1 { moved.insert(.left) }
        if abs(now.maxX - before.maxX) > 1 { moved.insert(.right) }
        if abs(now.minY - before.minY) > 1 { moved.insert(.top) }
        if abs(now.maxY - before.maxY) > 1 { moved.insert(.bottom) }
        guard let grid = Self.grid(for: now, areas: Self.usableAreas()) else { return }
        let target = Self.snapped(now, to: grid, edges: moved)
        guard target != now, let element = axWindow(pid: pressed.pid, frame: now) else { return }
        // Keep the edges that weren't dragged in place: dragging the left
        // edge leaves any gap there, not at the right.
        var anchoring: Edges = []
        anchoring.insert(moved.contains(.left) && !moved.contains(.right) ? .right : .left)
        anchoring.insert(moved.contains(.top) && !moved.contains(.bottom) ? .bottom : .top)
        Self.fit(element, into: target, anchoring: anchoring)
    }

    // MARK: Grid geometry

    /// Each screen's usable area, in global coordinates (top left origin).
    static func usableAreas() -> [CGRect] {
        // AppKit's coordinates have their origin at the bottom left of the
        // first screen (the one with the menu bar).
        guard let height = NSScreen.screens.first?.frame.height else { return [] }
        return NSScreen.screens.map { screen in
            let visible = screen.visibleFrame
            return CGRect(x: visible.minX, y: height - visible.maxY, width: visible.width, height: visible.height)
        }
    }

    static func grid(for area: CGRect) -> Grid {
        let landscape = area.width >= area.height
        let short = landscape ? area.height : area.width
        let long = landscape ? area.width : area.height
        let across = max(1, Int((long / (short / CGFloat(cellsAlongShortSide))).rounded()))
        let columns = landscape ? across : cellsAlongShortSide
        let rows = landscape ? cellsAlongShortSide : across
        return Grid(xs: (0...columns).map { (area.minX + area.width * CGFloat($0) / CGFloat(columns)).rounded() },
                    ys: (0...rows).map { (area.minY + area.height * CGFloat($0) / CGFloat(rows)).rounded() })
    }

    /// The grid of the screen with most of the window on it.
    private static func grid(for frame: CGRect, areas: [CGRect]) -> Grid? {
        let overlaps = areas.map { area -> CGFloat in
            let common = area.intersection(frame)
            return common.isNull ? 0 : common.width * common.height
        }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 else {
            return nil
        }
        return grid(for: areas[best])
    }

    /// `frame` with the given edges moved to the nearest grid lines, keeping
    /// at least one cell between opposite edges.
    static func snapped(_ frame: CGRect, to grid: Grid, edges: Edges) -> CGRect {
        func snap(_ low: CGFloat, _ high: CGFloat, _ lines: [CGFloat], snapLow: Bool, snapHigh: Bool)
            -> (CGFloat, CGFloat) {
            var lowIndex = nearest(low, in: lines), highIndex = nearest(high, in: lines)
            if snapLow, snapHigh, highIndex <= lowIndex {
                if lowIndex + 1 < lines.count { highIndex = lowIndex + 1 } else { lowIndex = highIndex - 1 }
            } else if snapLow, !snapHigh, lines[lowIndex] >= high {
                lowIndex = max(0, lines.lastIndex { $0 < high } ?? 0)
            } else if snapHigh, !snapLow, lines[highIndex] <= low {
                highIndex = min(lines.count - 1, lines.firstIndex { $0 > low } ?? lines.count - 1)
            }
            return (snapLow ? lines[lowIndex] : low, snapHigh ? lines[highIndex] : high)
        }
        let (minX, maxX) = snap(frame.minX, frame.maxX, grid.xs,
                                snapLow: edges.contains(.left), snapHigh: edges.contains(.right))
        let (minY, maxY) = snap(frame.minY, frame.maxY, grid.ys,
                                snapLow: edges.contains(.top), snapHigh: edges.contains(.bottom))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func nearest(_ value: CGFloat, in lines: [CGFloat]) -> Int {
        lines.indices.min { abs(lines[$0] - value) < abs(lines[$1] - value) } ?? 0
    }

    // MARK: Windows

    private struct WindowInfo {
        let number: CGWindowID
        let pid: pid_t
        let frame: CGRect
    }

    /// Normal windows on screen, front to back, other than our own and tiny
    /// ones (palettes, popups).
    private static func windowList() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict),
                  frame.width >= 100, frame.height >= 60 else { return nil }
            return WindowInfo(number: number, pid: pid, frame: frame)
        }
    }

    private static func frame(of number: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], number) as? [[String: Any]])?.first,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: boundsDict)
    }

    /// Whether the window can be resized, and isn't in full screen.
    private static func isResizable(_ window: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        var fullScreen: CFTypeRef?
        AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen)
        return (fullScreen as? Bool) != true
    }
}
