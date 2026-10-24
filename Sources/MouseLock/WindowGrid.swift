import AppKit
import Carbon.HIToolbox

/// Window Grid: each screen's usable area (without menu bar and Dock) is
/// divided into roughly square cells, 6 along its short side by default
/// (Window Grid Size in the menu). While it's on,
/// a window that was resized has the edges that moved snapped to the nearest
/// grid lines, and one that was moved lines up with them; a preview shows
/// where while dragging. Turning it on (or starting with it on) arranges all
/// windows on the grid without overlapping.
final class WindowGrid {
    /// Cells along each screen's short side (menu choice, remembered).
    static var cellsAlongShortSide: Int {
        get { UserDefaults.standard.object(forKey: "gridCellsAlongShortSide") as? Int ?? 6 }
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
    /// Whether the mouse moved while pressed: only a drag counts. An app may
    /// change a window's frame during a mere click (say gvim fitting its
    /// size to whole characters just after opening).
    private var dragged = false
    /// Esc pressed during this drag: on release the window goes back to
    /// where it was, and nothing else changes.
    private var aborted = false
    /// Taps Esc, to abort a drag (an active tap, so it can keep that Esc
    /// from the app).
    private var keyTap: CFMachPort?
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
        log("arranging all windows")
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
                log("arranging: \(window.frame) -> \(target)")
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

    /// Puts a new window on the grid of the screen with the pointer. In free
    /// space: at the size it opened at, rounded to whole cells, or as much of
    /// that as fits (at least its smallest size, and one cell), nearest the
    /// middle. With no free space: at its smallest size, on top of other
    /// windows where it hides the smallest share of any one of them (partly
    /// covering several rather than hiding one). It never pushes others aside.
    private func place(_ window: AXUIElement) {
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        let pointer = pointerLocation()
        let areas = Self.usableAreas()
        guard enabled, (subrole as? String) == kAXStandardWindowSubrole as String, Self.isResizable(window),
              !Self.isNewTab(window),
              let frame = axFrame(window), frame.width >= 100, frame.height >= 60,
              let area = areas.first(where: { $0.contains(pointer) }) ?? Self.area(for: frame, areas: areas)
        else { return }
        let grid = Self.grid(for: area)
        let cell = CGSize(width: grid.xs[1] - grid.xs[0], height: grid.ys[1] - grid.ys[0])

        // Its smallest size: ask for a tiny one, and see what the app allows.
        var tiny = CGSize(width: 1, height: 1)
        if let value = AXValueCreate(.cgSize, &tiny) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
        let smallest = axFrame(window)?.size ?? cell
        let columns = min(grid.xs.count - 1, max(1, Int((smallest.width / cell.width - 0.05).rounded(.up))))
        let rows = min(grid.ys.count - 1, max(1, Int((smallest.height / cell.height - 0.05).rounded(.up))))

        var number = CGWindowID(0)
        let known = _AXUIElementGetWindow(window, &number) == .success
        let others = Self.windowList().filter { other in
            (known ? other.number != number : !Self.sameFrame(other.frame, frame))
                && Self.overlapArea(other.frame, area) > 0
        }.map(\.frame)

        func spot(_ left: Int, _ top: Int, _ columns: Int, _ rows: Int) -> CGRect {
            CGRect(x: grid.xs[left], y: grid.ys[top], width: grid.xs[left + columns] - grid.xs[left],
                   height: grid.ys[top + rows] - grid.ys[top])
        }
        let middle = { (rect: CGRect) in hypot(rect.midX - area.midX, rect.midY - area.midY) }

        // In free space: the size it opened at (in whole cells) if that fits,
        // else as much of it as does; the largest such spot, nearest the middle.
        let wantedColumns = min(grid.xs.count - 1, max(columns, Int((frame.width / cell.width).rounded())))
        let wantedRows = min(grid.ys.count - 1, max(rows, Int((frame.height / cell.height).rounded())))
        var free: (rect: CGRect, score: (CGFloat, CGFloat))?
        for width in columns...wantedColumns {
            for height in rows...wantedRows {
                for left in 0...(grid.xs.count - 1 - width) {
                    for top in 0...(grid.ys.count - 1 - height) {
                        let rect = spot(left, top, width, height)
                        guard !others.contains(where: { Self.overlapArea($0, rect) > 1 }) else { continue }
                        let score = (-rect.width * rect.height, middle(rect))
                        if free.map({ score < $0.score }) ?? true { free = (rect, score) }
                    }
                }
            }
        }
        if let target = free?.rect {
            log("new window \(frame), smallest \(smallest); into free space at \(target)")
            Self.fit(window, into: target, anchoring: [.left, .top])
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return
        }

        // No free space: at its smallest, on top. Score each spot: the largest
        // share of one window it hides, then the total area it covers, then
        // how far it is from the middle.
        var best: (rect: CGRect, score: (CGFloat, CGFloat, CGFloat))?
        for left in 0...(grid.xs.count - 1 - columns) {
            for top in 0...(grid.ys.count - 1 - rows) {
                let rect = spot(left, top, columns, rows)
                let covered = others.map { Self.overlapArea($0, rect) }
                let share = zip(others, covered).map { $1 / max(1, $0.width * $0.height) }.max() ?? 0
                let score = (share, covered.reduce(0, +), middle(rect))
                if best.map({ score < $0.score }) ?? true { best = (rect, score) }
            }
        }
        guard let target = best?.rect else { return }
        log("new window \(frame), smallest \(smallest); placed at \(target)")
        Self.fit(window, into: target, anchoring: [.left, .top])
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// Whether `window` is a tab added to an existing window: with macOS's
    /// own window tabs (Terminal, Finder) each tab is a window of its own,
    /// sharing the frame, so placing it would resize the whole group. It then
    /// has a tab bar with at least two tabs.
    private static func isNewTab(_ window: AXUIElement) -> Bool {
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children)
        return (children as? [AXUIElement] ?? []).contains { child in
            var role: CFTypeRef?, tabs: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            guard (role as? String) == kAXTabGroupRole as String else { return false }
            AXUIElementCopyAttributeValue(child, kAXTabsAttribute as CFString, &tabs)
            return (tabs as? [AXUIElement])?.count ?? 0 >= 2
        }
    }

    // MARK: Pushing and pulling

    private struct Direction: OptionSet {
        let rawValue: Int
        static let left = Direction(rawValue: 1)
        static let right = Direction(rawValue: 2)
        static let up = Direction(rawValue: 4)
        static let down = Direction(rawValue: 8)
    }

    /// After a drag took window `number` from `before` to `after`: only
    /// windows directly involved change, never ones further along. Windows
    /// against an edge that was dragged follow it with their near edge,
    /// growing or shrinking
    /// (pull and push). Windows it then overlaps are trimmed on the side
    /// facing it, down to one cell; if that isn't enough, one may move
    /// instead, but only into free space. Otherwise it's left overlapping,
    /// never pushed off the screen.
    private static func makeRoom(for number: CGWindowID, from before: CGRect, to after: CGRect) {
        let areas = usableAreas()
        let onScreen = { (rect: CGRect) in areas.contains { $0.insetBy(dx: -1, dy: -1).contains(rect) } }
        for (other, frame) in roomPlan(for: number, from: before, to: after) {
            guard let element = axWindow(pid: other.pid, frame: other.frame) else { continue }
            log("making room: \(other.frame) -> \(frame)")
            fit(element, into: frame, anchoring: [.left, .top])
            // An app may not let it get that small (a minimum size). If it
            // overlaps anyway, or now sticks out past the screen's edge, it
            // might as well keep its size and place.
            if let actual = axFrame(element),
               overlapArea(actual, after) > 1 || (onScreen(frame) && !onScreen(actual)) {
                log("still overlapping or off screen at \(actual); back to \(other.frame)")
                setAXFrame(element, other.frame)
            }
        }
    }

    /// The windows `makeRoom` would change, and how: also for the preview.
    private static func roomPlan(for number: CGWindowID, from before: CGRect,
                                 to after: CGRect) -> [(WindowInfo, CGRect)] {
        guard let area = area(for: after, areas: usableAreas()) else { return [] }
        let grid = grid(for: area)
        let cell = CGSize(width: grid.xs[1] - grid.xs[0], height: grid.ys[1] - grid.ys[0])
        // Neighbours may sit a little apart (an app rounding its size).
        let near = min(cell.width, cell.height) / 4
        let others = windowList().filter { $0.number != number && overlapArea($0.frame, area) > 0 }
        var frames = Dictionary(uniqueKeysWithValues: others.map { ($0.number, $0.frame) })
        let resized = abs(after.width - before.width) > 1 || abs(after.height - before.height) > 1

        var directions: Direction = []
        if resized {
            if after.maxX > before.maxX + 1 { directions.insert(.right) }
            if after.minX < before.minX - 1 { directions.insert(.left) }
            if after.maxY > before.maxY + 1 { directions.insert(.down) }
            if after.minY < before.minY - 1 { directions.insert(.up) }
            // Edges that moved take the near edge of the windows against them
            // along, as long as those keep at least one cell.
            for other in others {
                let frame = other.frame
                let besideY = frame.minY < before.maxY - 1 && frame.maxY > before.minY + 1
                let besideX = frame.minX < before.maxX - 1 && frame.maxX > before.minX + 1
                var edges = (minX: frame.minX, maxX: frame.maxX, minY: frame.minY, maxY: frame.maxY)
                if besideY, abs(after.maxX - before.maxX) > 1, abs(frame.minX - before.maxX) <= near {
                    edges.minX = after.maxX
                } else if besideY, abs(after.minX - before.minX) > 1, abs(frame.maxX - before.minX) <= near {
                    edges.maxX = after.minX
                }
                if besideX, abs(after.maxY - before.maxY) > 1, abs(frame.minY - before.maxY) <= near {
                    edges.minY = after.maxY
                } else if besideX, abs(after.minY - before.minY) > 1, abs(frame.maxY - before.minY) <= near {
                    edges.maxY = after.minY
                }
                let followed = CGRect(x: edges.minX, y: edges.minY,
                                      width: edges.maxX - edges.minX, height: edges.maxY - edges.minY)
                if followed.width >= cell.width - 1, followed.height >= cell.height - 1 {
                    frames[other.number] = followed
                }
            }
        } else {
            if after.minX > before.minX + 1 { directions.insert(.right) }
            if after.minX < before.minX - 1 { directions.insert(.left) }
            if after.minY > before.minY + 1 { directions.insert(.down) }
            if after.minY < before.minY - 1 { directions.insert(.up) }
        }

        // Windows still overlapping it: trim, or else move into free space.
        for other in others {
            guard let frame = frames[other.number], overlapArea(frame, after) > 1 else { continue }
            var rest = frames
            rest[other.number] = nil
            if let trimmed = trim(frame, clearOf: after, directions: directions, cell: cell) {
                frames[other.number] = trimmed
            } else if let moved = move(frame, clearOf: after, directions: directions, within: area,
                                       avoiding: Array(rest.values)) {
                frames[other.number] = moved
            }
        }

        return others.compactMap { other in
            frames[other.number].flatMap { sameFrame($0, other.frame) ? nil : (other, $0) }
        }
    }

    /// `frame` with one edge pulled back so it no longer overlaps `pusher`,
    /// keeping at least one cell: whichever side loses least area (on a
    /// tie, the side matching `directions`). Nil if no side works.
    private static func trim(_ frame: CGRect, clearOf pusher: CGRect, directions: Direction,
                             cell: CGSize) -> CGRect? {
        let options: [(Direction, CGRect)] = [
            (.right, CGRect(x: pusher.maxX, y: frame.minY, width: frame.maxX - pusher.maxX, height: frame.height)),
            (.left, CGRect(x: frame.minX, y: frame.minY, width: pusher.minX - frame.minX, height: frame.height)),
            (.down, CGRect(x: frame.minX, y: pusher.maxY, width: frame.width, height: frame.maxY - pusher.maxY)),
            (.up, CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: pusher.minY - frame.minY)),
        ].filter { $0.1.width >= cell.width - 1 && $0.1.height >= cell.height - 1 }
        return options.max { a, b in
            let areaA = (a.1.width * a.1.height).rounded(), areaB = (b.1.width * b.1.height).rounded()
            return areaA != areaB ? areaA < areaB : !directions.contains(a.0) && directions.contains(b.0)
        }?.1
    }

    /// `frame` moved just clear of `pusher` (the way of `directions` if
    /// possible), if it then fits within `area` without overlapping anything.
    private static func move(_ frame: CGRect, clearOf pusher: CGRect, directions: Direction,
                             within area: CGRect, avoiding taken: [CGRect]) -> CGRect? {
        let moves: [(Direction, CGRect)] = [
            (.right, frame.offsetBy(dx: pusher.maxX - frame.minX, dy: 0)),
            (.left, frame.offsetBy(dx: pusher.minX - frame.maxX, dy: 0)),
            (.down, frame.offsetBy(dx: 0, dy: pusher.maxY - frame.minY)),
            (.up, frame.offsetBy(dx: 0, dy: pusher.minY - frame.maxY)),
        ].filter { move in
            area.insetBy(dx: -1, dy: -1).contains(move.1) && !taken.contains { overlapArea($0, move.1) > 1 }
        }
        let preferred = moves.filter { directions.contains($0.0) }
        let distance = { (rect: CGRect) in abs(rect.minX - frame.minX) + abs(rect.minY - frame.minY) }
        return (preferred.isEmpty ? moves : preferred).min { distance($0.1) < distance($1.1) }?.1
    }

    private func log(_ message: String) { Self.log(message) }

    private static func log(_ message: String) {
        guard debugLogging else { return }
        FileHandle.standardError.write("window grid: \(message)\n".data(using: .utf8)!)
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
        aborted = false
        preview.hide()
        if !enabled {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: false) }
            return
        }
        guard let tap = ensureTap() else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        if let keyTap = ensureKeyTap() { CGEvent.tapEnable(tap: keyTap, enable: true) }
    }

    private func ensureKeyTap() -> CFMachPort? {
        if let keyTap, EventTaps.isLive(keyTap) { return keyTap }
        guard EventTaps.permitted else { return nil }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let grid = Unmanaged<WindowGrid>.fromOpaque(refcon!).takeUnretainedValue()
            return grid.handleKey(type: type, event: event)
        }
        guard let keyTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }

        let source = CFMachPortCreateRunLoopSource(nil, keyTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.keyTap = keyTap
        EventTaps.add(keyTap)
        return keyTap
    }

    /// Esc while a window is being moved or resized aborts that: the window
    /// still follows the pointer (macOS's drag can't be stopped), but goes
    /// back on release. That Esc is kept from the app; any other passes.
    private func handleKey(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if enabled, let keyTap { CGEvent.tapEnable(tap: keyTap, enable: true) }
            return pass
        }
        guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape),
              let pressed, dragged else { return pass }
        if aborted { return nil }
        guard type == .keyDown, let now = Self.frame(of: pressed.number),
              !Self.sameFrame(now, pressed.frame) else { return pass }
        log("drag aborted; back to \(pressed.frame) on release")
        aborted = true
        previewWork?.cancel()
        previewWork = nil
        preview.show(pressed.frame)
        return nil
    }

    private func ensureTap() -> CFMachPort? {
        if let tap, EventTaps.isLive(tap) { return tap }
        guard EventTaps.permitted else { return nil }
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
        EventTaps.add(tap)
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
            dragged = false
            aborted = false
        case .leftMouseDragged:
            dragged = true
            // Aborted: the outline stays on where the window goes back to.
            if aborted { return }
            // Control held (pressed once dragging: held at the press, it makes
            // a right-click): still onto the cells, but other windows are left
            // alone, overlapping if need be.
            let pushOthers = !event.flags.contains(.maskControl)
            // Show where the window would snap, about 30 times a second at most.
            guard pressed != nil, previewWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                previewWork = nil
                guard let pressed, let now = Self.frame(of: pressed.number),
                      let snap = Self.snap(from: pressed.frame, to: now) else { return preview.hide() }
                let others = pushOthers
                    ? Self.roomPlan(for: pressed.number, from: pressed.frame, to: snap.target) : []
                preview.show(snap.target, others: others.map(\.1))
            }
            previewWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
        case .leftMouseUp:
            previewWork?.cancel()
            previewWork = nil
            preview.hide()
            guard let pressed, dragged else { self.pressed = nil; return }
            self.pressed = nil
            if aborted {
                aborted = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard let now = Self.frame(of: pressed.number),
                          let element = axWindow(pid: pressed.pid, frame: now) else { return }
                    setAXFrame(element, pressed.frame)
                }
                return
            }
            let pushOthers = !event.flags.contains(.maskControl)
            // Let the app finish the resize or move first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, enabled, let now = Self.frame(of: pressed.number),
                      let snap = Self.snap(from: pressed.frame, to: now),
                      let element = axWindow(pid: pressed.pid, frame: now) else { return }
                if snap.target != now { Self.fit(element, into: snap.target, anchoring: snap.anchoring) }
                if pushOthers {
                    Self.makeRoom(for: pressed.number, from: pressed.frame, to: axFrame(element) ?? snap.target)
                }
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
        usableScreens().map(\.area)
    }

    /// Each screen's name and usable area, main screen first.
    static func usableScreens() -> [(name: String, area: CGRect)] {
        // AppKit's coordinates have their origin at the bottom left of the
        // first screen (the one with the menu bar).
        guard let height = NSScreen.screens.first?.frame.height else { return [] }
        return NSScreen.screens.map { screen in
            let visible = screen.visibleFrame
            return (screen.localizedName,
                    CGRect(x: visible.minX, y: height - visible.maxY, width: visible.width, height: visible.height))
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
    /// One panel per outline, reused: the first for the dragged window, the
    /// rest for windows that would make room.
    private var panels: [NSPanel] = []

    /// Frames in global coordinates (top left origin).
    func show(_ frame: CGRect, others: [CGRect] = []) {
        guard let height = NSScreen.screens.first?.frame.height else { return }
        for (index, rect) in ([frame] + others).enumerated() {
            if index == panels.count { panels.append(makePanel(main: index == 0)) }
            panels[index].setFrame(NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width,
                                          height: rect.height), display: true)
            panels[index].orderFrontRegardless()
        }
        for panel in panels.dropFirst(1 + others.count) { panel.orderOut(nil) }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
    }

    private func makePanel(main: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let color = main ? NSColor.controlAccentColor : NSColor.systemGray
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.borderWidth = 2
        view.layer?.borderColor = color.withAlphaComponent(0.8).cgColor
        view.layer?.backgroundColor = color.withAlphaComponent(main ? 0.15 : 0.1).cgColor
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        return panel
    }
}
