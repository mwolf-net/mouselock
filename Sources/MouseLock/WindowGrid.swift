import AppKit

/// Window Grid: each screen's usable area (without menu bar and Dock) is
/// divided into roughly square cells, 4 along its short side by default
/// (Window Grid Size in the menu). While it's on,
/// a window that was resized has the edges that moved snapped to the nearest
/// grid lines, and one that was moved lines up with them; a preview shows
/// where while dragging. Turning it on (or starting with it on) arranges all
/// windows on the grid without overlapping.
final class WindowGrid {
    /// Cells along each screen's short side (menu choice, remembered).
    static var cellsAlongShortSide: Int {
        get { UserDefaults.standard.object(forKey: "gridCellsAlongShortSide") as? Int ?? 4 }
        set { UserDefaults.standard.set(newValue, forKey: "gridCellsAlongShortSide") }
    }
    static let sizeChoices = Array(2...10)

    var enabled = false {
        didSet {
            updateTap()
            updateObservers()
        }
    }

    private var tap: CFMachPort?
    /// The window under a press, and its frame then.
    private var pressed: (number: CGWindowID, pid: pid_t, frame: CGRect)?
    private let preview = GridPreview()
    private var previewWork: DispatchWorkItem?

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

    /// Snaps all windows on screen to the grid without overlapping, front to
    /// back: each gets the grid rectangle closest to where it is (its edges
    /// moving least in all) among those still free. If no free one keeps at
    /// least half its area, it gets its nearest one anyway, overlapping
    /// rather than shrinking to a sliver. Windows that can't be resized stay
    /// put, taking up their space.
    func arrangeAll() {
        let areas = Self.usableAreas()
        var taken: [CGRect] = []
        for window in Self.windowList() {
            guard let element = axWindow(pid: window.pid, frame: window.frame) else { continue }
            guard Self.isResizable(element), let grid = Self.grid(for: window.frame, areas: areas) else {
                taken.append(window.frame)
                continue
            }
            let target = Self.closestFree(to: window.frame, in: grid, avoiding: taken)
                ?? Self.snapped(window.frame, to: grid, edges: .all)
            if target != window.frame {
                Self.fit(element, into: target, anchoring: [.left, .top])
            }
            taken.append(axFrame(element) ?? target)
        }
    }

    /// The grid rectangle whose edges are closest to `frame`'s in all, among
    /// those not overlapping `taken` and at least half its area.
    private static func closestFree(to frame: CGRect, in grid: Grid, avoiding taken: [CGRect]) -> CGRect? {
        var best: (rect: CGRect, cost: CGFloat)?
        for left in grid.xs.indices.dropLast() {
            for right in grid.xs.indices where right > left {
                for top in grid.ys.indices.dropLast() {
                    for bottom in grid.ys.indices where bottom > top {
                        let rect = CGRect(x: grid.xs[left], y: grid.ys[top], width: grid.xs[right] - grid.xs[left],
                                          height: grid.ys[bottom] - grid.ys[top])
                        let cost = abs(rect.minX - frame.minX) + abs(rect.maxX - frame.maxX)
                            + abs(rect.minY - frame.minY) + abs(rect.maxY - frame.maxY)
                        guard cost < best?.cost ?? .infinity,
                              rect.width * rect.height >= frame.width * frame.height / 2,
                              !taken.contains(where: { overlapArea($0, rect) > 1 }) else { continue }
                        best = (rect, cost)
                    }
                }
            }
        }
        return best?.rect
    }

    // MARK: New windows

    /// Per app, an observer for its new windows.
    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []

    private func updateObservers() {
        if !enabled {
            for (_, observer) in observers {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            observers = [:]
            workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
            workspaceObservers = []
            return
        }
        guard workspaceObservers.isEmpty, AXIsProcessTrusted() else { return }
        NSWorkspace.shared.runningApplications.forEach { observe($0) }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil,
                               queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                else { return }
                self?.observe(app)
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                               queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let observer = self?.observers.removeValue(forKey: app.processIdentifier) else { return }
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            },
        ]
    }

    /// Watches `app` for new windows. A just launched app may not answer
    /// yet, so this tries again a few times.
    private func observe(_ app: NSRunningApplication, attempt: Int = 0) {
        let pid = app.processIdentifier
        guard enabled, app.activationPolicy == .regular, pid != ProcessInfo.processInfo.processIdentifier,
              observers[pid] == nil, !app.isTerminated else { return }
        let callback: AXObserverCallback = { _, element, _, refcon in
            Unmanaged<WindowGrid>.fromOpaque(refcon!).takeUnretainedValue().windowCreated(element)
        }
        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let result = AXObserverAddNotification(observer, AXUIElementCreateApplication(pid),
                                               kAXWindowCreatedNotification as CFString,
                                               Unmanaged.passUnretained(self).toOpaque())
        guard result == .success else {
            if attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.observe(app, attempt: attempt + 1)
                }
            }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func windowCreated(_ window: AXUIElement) {
        // Let the app put the window where it wants first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.place(window)
        }
    }

    /// Puts a new window on the grid: in the closest free space if there's
    /// enough; otherwise it takes half of the largest window on its screen
    /// that spans at least two cells; failing that, its nearest grid spot.
    private func place(_ window: AXUIElement) {
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        guard enabled, (subrole as? String) == kAXStandardWindowSubrole as String, Self.isResizable(window),
              let frame = axFrame(window), frame.width >= 100, frame.height >= 60,
              let area = Self.area(for: frame, areas: Self.usableAreas()) else { return }
        let grid = Self.grid(for: area)
        var number = CGWindowID(0)
        let known = _AXUIElementGetWindow(window, &number) == .success
        let others = Self.windowList().filter { other in
            (known ? other.number != number : !Self.sameFrame(other.frame, frame))
                && Self.overlapArea(other.frame, area) > 0
        }
        log("new window \(frame); others \(others.map(\.frame))")
        if let free = Self.closestFree(to: frame, in: grid, avoiding: others.map(\.frame)) {
            log("into free space \(free)")
            Self.fit(window, into: free, anchoring: [.left, .top])
            return
        }
        for other in others.sorted(by: { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }) {
            let snapped = Self.snapped(other.frame, to: grid, edges: .all)
            guard let halves = Self.halves(of: snapped, in: grid),
                  let element = axWindow(pid: other.pid, frame: other.frame), Self.isResizable(element)
            else { continue }
            log("splitting \(other.frame) into \(halves.0) and \(halves.1)")
            Self.fit(element, into: halves.0, anchoring: [.left, .top])
            // The other window may not shrink that far (a minimum size): then
            // the split moves to the next grid line past it, and it fills up to
            // there, so there's no gap. If that leaves no room, it gets its
            // space back and the new window its nearest spot.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                var rest = halves.1
                let alongX = halves.1.minX > halves.0.minX
                if let kept = axFrame(element), (alongX ? kept.maxX : kept.maxY) > (alongX ? rest.minX : rest.minY) + 1 {
                    let lines = alongX ? grid.xs : grid.ys
                    let end = alongX ? rest.maxX : rest.maxY
                    let split = lines.first { $0 >= (alongX ? kept.maxX : kept.maxY) - 1 } ?? end
                    if split < end {
                        let first = alongX
                            ? CGRect(x: snapped.minX, y: snapped.minY, width: split - snapped.minX, height: snapped.height)
                            : CGRect(x: snapped.minX, y: snapped.minY, width: snapped.width, height: split - snapped.minY)
                        rest = alongX
                            ? CGRect(x: split, y: rest.minY, width: end - split, height: rest.height)
                            : CGRect(x: rest.minX, y: split, width: rest.width, height: end - split)
                        Self.log("kept \(kept); split moves: \(first) and \(rest)")
                        Self.fit(element, into: first, anchoring: [.left, .top])
                    } else {
                        Self.log("kept \(kept); no room left, giving its space back")
                        Self.fit(element, into: snapped, anchoring: [.left, .top])
                        rest = Self.snapped(frame, to: grid, edges: .all)
                    }
                }
                Self.fit(window, into: rest, anchoring: [.left, .top])
            }
            return
        }
        log("no room; nearest spot")
        Self.fit(window, into: Self.snapped(frame, to: grid, edges: .all), anchoring: [.left, .top])
    }

    private func log(_ message: String) { Self.log(message) }

    private static func log(_ message: String) {
        guard debugLogging else { return }
        FileHandle.standardError.write("window grid: \(message)\n".data(using: .utf8)!)
    }

    /// `rect` (on grid lines) split in two along its longer side, on the grid
    /// line nearest its middle (if two are, the first part, which the window
    /// being split keeps, gets the larger one); nil if it's only one cell
    /// that way.
    private static func halves(of rect: CGRect, in grid: Grid) -> (CGRect, CGRect)? {
        let alongX = rect.width >= rect.height
        let lines = (alongX ? grid.xs : grid.ys).filter { line in
            alongX ? line > rect.minX && line < rect.maxX : line > rect.minY && line < rect.maxY
        }
        guard !lines.isEmpty else { return nil }
        let mid = alongX ? rect.midX : rect.midY
        let middle = lines.min { a, b in abs(a - mid) != abs(b - mid) ? abs(a - mid) < abs(b - mid) : a > b }!
        return alongX
            ? (CGRect(x: rect.minX, y: rect.minY, width: middle - rect.minX, height: rect.height),
               CGRect(x: middle, y: rect.minY, width: rect.maxX - middle, height: rect.height))
            : (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: middle - rect.minY),
               CGRect(x: rect.minX, y: middle, width: rect.width, height: rect.maxY - middle))
    }

    private static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2
            && abs(a.height - b.height) < 2
    }

    private static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let common = a.intersection(b)
        return common.isNull ? 0 : common.width * common.height
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

    // MARK: Snapping after a resize or move

    private func updateTap() {
        pressed = nil
        preview.hide()
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
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
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
        case .leftMouseDragged:
            // Show where the window would snap, about 30 times a second at most.
            guard pressed != nil, previewWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                previewWork = nil
                guard let pressed, let now = Self.frame(of: pressed.number),
                      let snap = Self.snap(from: pressed.frame, to: now) else { return preview.hide() }
                preview.show(snap.target)
            }
            previewWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
        case .leftMouseUp:
            previewWork?.cancel()
            previewWork = nil
            preview.hide()
            guard let pressed else { return }
            self.pressed = nil
            // Let the app finish the resize or move first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, enabled, let now = Self.frame(of: pressed.number),
                      let snap = Self.snap(from: pressed.frame, to: now), snap.target != now,
                      let element = axWindow(pid: pressed.pid, frame: now) else { return }
                Self.fit(element, into: snap.target, anchoring: snap.anchoring)
            }
        default:
            break
        }
    }

    private struct Snap {
        let target: CGRect
        let anchoring: Edges
    }

    /// Where a window that went from `before` to `now` snaps to, if it was
    /// resized or moved. Resized: the edges that moved go to the nearest grid
    /// lines. Moved: the whole window shifts to line up with the grid, by
    /// whichever edge is closest to a line.
    private static func snap(from before: CGRect, to now: CGRect) -> Snap? {
        guard let grid = grid(for: now, areas: usableAreas()) else { return nil }
        if abs(now.width - before.width) > 1 || abs(now.height - before.height) > 1 {
            var moved: Edges = []
            if abs(now.minX - before.minX) > 1 { moved.insert(.left) }
            if abs(now.maxX - before.maxX) > 1 { moved.insert(.right) }
            if abs(now.minY - before.minY) > 1 { moved.insert(.top) }
            if abs(now.maxY - before.maxY) > 1 { moved.insert(.bottom) }
            // Keep the edges that weren't dragged in place: dragging the left
            // edge leaves any gap there, not at the right.
            var anchoring: Edges = []
            anchoring.insert(moved.contains(.left) && !moved.contains(.right) ? .right : .left)
            anchoring.insert(moved.contains(.top) && !moved.contains(.bottom) ? .bottom : .top)
            return Snap(target: snapped(now, to: grid, edges: moved), anchoring: anchoring)
        }
        if abs(now.minX - before.minX) > 1 || abs(now.minY - before.minY) > 1 {
            func shift(_ low: CGFloat, _ high: CGFloat, _ lines: [CGFloat]) -> CGFloat {
                let toLow = lines[nearest(low, in: lines)] - low
                let toHigh = lines[nearest(high, in: lines)] - high
                return abs(toLow) <= abs(toHigh) ? toLow : toHigh
            }
            let target = now.offsetBy(dx: shift(now.minX, now.maxX, grid.xs), dy: shift(now.minY, now.maxY, grid.ys))
            return Snap(target: target, anchoring: [.left, .top])
        }
        return nil
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

    /// Columns and rows for an area with `cells` along its short side, the
    /// other side getting as many as keeps the cells closest to square.
    static func dimensions(of area: CGRect, cells: Int = cellsAlongShortSide) -> (columns: Int, rows: Int) {
        let landscape = area.width >= area.height
        let short = landscape ? area.height : area.width
        let long = landscape ? area.width : area.height
        let across = max(1, Int((long / (short / CGFloat(cells))).rounded()))
        return landscape ? (across, cells) : (cells, across)
    }

    static func grid(for area: CGRect) -> Grid {
        let (columns, rows) = dimensions(of: area)
        return Grid(xs: (0...columns).map { (area.minX + area.width * CGFloat($0) / CGFloat(columns)).rounded() },
                    ys: (0...rows).map { (area.minY + area.height * CGFloat($0) / CGFloat(rows)).rounded() })
    }

    /// The grid of the screen with most of the window on it.
    private static func grid(for frame: CGRect, areas: [CGRect]) -> Grid? {
        area(for: frame, areas: areas).map { grid(for: $0) }
    }

    /// The usable area of the screen with most of `frame` on it.
    private static func area(for frame: CGRect, areas: [CGRect]) -> CGRect? {
        let overlaps = areas.map { overlapArea($0, frame) }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 else {
            return nil
        }
        return areas[best]
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

/// The outline of where a dragged window will snap to.
private final class GridPreview {
    private var panel: NSPanel?

    /// `frame` in global coordinates (top left origin).
    func show(_ frame: CGRect) {
        guard let height = NSScreen.screens.first?.frame.height else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(NSRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height),
                       display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.borderWidth = 2
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        return panel
    }
}
