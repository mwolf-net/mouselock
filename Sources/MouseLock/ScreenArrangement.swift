import CoreGraphics

/// Placing a laptop's external screens, as in System Settings > Displays >
/// Arrange. The arrangement is seen as a row of screens, left to right with
/// their bottoms aligned, plus at most one screen above each screen in the
/// row, centred on it. An external screen can go anywhere in the row, or
/// above a screen in the row.
enum ScreenArrangement {
    struct Layout {
        /// Left to right.
        var row: [CGDirectDisplayID]
        /// Screen in the row -> the screen above it.
        var above: [CGDirectDisplayID: CGDirectDisplayID]
    }

    enum Placement: Equatable {
        /// In the row, just left of this screen.
        case leftOf(CGDirectDisplayID)
        /// At the right end of the row, right of this screen.
        case rightOf(CGDirectDisplayID)
        case above(CGDirectDisplayID)

        /// The screen it's relative to.
        var screen: CGDirectDisplayID {
            switch self {
            case .leftOf(let id), .rightOf(let id), .above(let id): return id
            }
        }

        /// Left, right, above.
        var order: Int {
            switch self {
            case .leftOf: return 0
            case .rightOf: return 1
            case .above: return 2
            }
        }
    }

    struct Option {
        let placement: Placement
        let title: String
        let isCurrent: Bool
    }

    /// The built-in screen and the external ones, if there is a built-in
    /// screen and at least one external one.
    static func laptopAndExternals() -> (builtin: Display, externals: [Display])? {
        let displays = Display.all()
        guard let builtin = displays.first(where: \.isBuiltin) else { return nil }
        let externals = displays.filter { !$0.isBuiltin }
        return externals.isEmpty ? nil : (builtin, externals)
    }

    /// Where `screen` can go, given the current arrangement of `displays`.
    static func options(for screen: CGDirectDisplayID, among displays: [Display]) -> [Option] {
        var layout = currentLayout(of: displays.map(\.id))
        layout.row.removeAll { $0 == screen }
        if let base = layout.above.first(where: { $0.value == screen })?.key {
            layout.above[base] = nil
        }
        let name = { (id: CGDirectDisplayID) in displays.first { $0.id == id }?.name ?? "Screen \(id)" }

        var placements = layout.row.map { (Placement.leftOf($0), "Left of \(name($0))") }
        if let last = layout.row.last {
            placements.append((.rightOf(last), "Right of \(name(last))"))
        }
        // A screen with another above it stays in the row (with that one).
        if layout.above[screen] == nil {
            placements += layout.row.filter { layout.above[$0] == nil }
                .map { (.above($0), "Above \(name($0))") }
        }
        let current = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, CGDisplayBounds($0.id)) })
        // Grouped by the screen they're relative to: the laptop's first, then
        // the others left to right, bottom to top.
        let builtin = displays.first(where: \.isBuiltin)?.id
        let screenOrder = displays.map(\.id).sorted { a, b in
            if (a == builtin) != (b == builtin) { return a == builtin }
            let fa = current[a]!, fb = current[b]!
            return fa.minX != fb.minX ? fa.minX < fb.minX : fa.maxY > fb.maxY
        }
        placements.sort { a, b in
            let ia = screenOrder.firstIndex(of: a.0.screen)!, ib = screenOrder.firstIndex(of: b.0.screen)!
            return ia != ib ? ia < ib : a.0.order < b.0.order
        }
        return placements.map { placement, title in
            let frames = self.frames(of: layout.placing(screen, placement))
            let isCurrent = frames.allSatisfy { id, frame in
                guard let now = current[id] else { return false }
                return abs(now.minX - frame.minX) < 1 && abs(now.minY - frame.minY) < 1
            }
            return Option(placement: placement, title: title, isCurrent: isCurrent)
        }
    }

    /// Moves `screen`, keeping the main display (with the menu bar) at the
    /// origin. Saved like a change in System Settings.
    @discardableResult
    static func place(_ screen: CGDirectDisplayID, _ placement: Placement,
                      among displays: [CGDirectDisplayID]) -> Bool {
        var layout = currentLayout(of: displays)
        layout.row.removeAll { $0 == screen }
        if let base = layout.above.first(where: { $0.value == screen })?.key {
            layout.above[base] = nil
        }
        let frames = frames(of: layout.placing(screen, placement))
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        for (id, frame) in frames {
            CGConfigureDisplayOrigin(config, id, Int32(frame.minX), Int32(frame.minY))
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    /// The current arrangement as a row plus screens above. A screen counts
    /// as above another if its bottom touches that one's top and they
    /// overlap sideways; everything else is in the row, by position.
    private static func currentLayout(of displays: [CGDirectDisplayID]) -> Layout {
        let bounds = Dictionary(uniqueKeysWithValues: displays.map { ($0, CGDisplayBounds($0)) })
        func base(of id: CGDirectDisplayID) -> CGDirectDisplayID? {
            let frame = bounds[id]!
            return displays.filter { other in
                let below = bounds[other]!
                return other != id && abs(frame.maxY - below.minY) < 1
                    && min(frame.maxX, below.maxX) > max(frame.minX, below.minX)
            }.max { a, b in
                overlap(frame, bounds[a]!) < overlap(frame, bounds[b]!)
            }
        }
        var layout = Layout(row: [], above: [:])
        var aboveScreens: [(CGDirectDisplayID, CGDirectDisplayID)] = []
        for id in displays {
            if let base = base(of: id) { aboveScreens.append((id, base)) } else { layout.row.append(id) }
        }
        // Only one per screen in the row, and not stacked: the rest joins the row.
        for (id, base) in aboveScreens {
            if layout.row.contains(base), layout.above[base] == nil {
                layout.above[base] = id
            } else {
                layout.row.append(id)
            }
        }
        layout.row.sort { bounds[$0]!.minX < bounds[$1]!.minX }
        return layout
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        min(a.maxX, b.maxX) - max(a.minX, b.minX)
    }

    /// Each screen's frame for a layout, shifted so the main display is at
    /// the origin.
    private static func frames(of layout: Layout) -> [CGDirectDisplayID: CGRect] {
        var frames: [CGDirectDisplayID: CGRect] = [:]
        var x: CGFloat = 0
        for id in layout.row {
            let size = CGDisplayBounds(id).size
            frames[id] = CGRect(x: x, y: -size.height, width: size.width, height: size.height)
            x += size.width
            if let top = layout.above[id] {
                let base = frames[id]!
                let topSize = CGDisplayBounds(top).size
                frames[top] = CGRect(x: (base.midX - topSize.width / 2).rounded(), y: base.minY - topSize.height,
                                     width: topSize.width, height: topSize.height)
            }
        }
        guard let main = frames[CGMainDisplayID()] else { return frames }
        return frames.mapValues { $0.offsetBy(dx: -main.minX, dy: -main.minY) }
    }
}

private extension ScreenArrangement.Layout {
    /// This layout with `screen` (not in it yet) added at `placement`.
    func placing(_ screen: CGDirectDisplayID, _ placement: ScreenArrangement.Placement) -> Self {
        var layout = self
        switch placement {
        case .leftOf(let other):
            layout.row.insert(screen, at: layout.row.firstIndex(of: other) ?? 0)
        case .rightOf(let other):
            layout.row.insert(screen, at: (layout.row.firstIndex(of: other) ?? layout.row.count - 1) + 1)
        case .above(let other):
            layout.above[other] = screen
        }
        return layout
    }
}
