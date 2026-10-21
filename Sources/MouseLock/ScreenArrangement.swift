import CoreGraphics

/// Placing a laptop's one external screen left of, right of or above the
/// built-in screen, as in System Settings > Displays > Arrange. Bottoms are
/// aligned for left and right, centres for above.
enum ScreenPosition: CaseIterable {
    case left, right, above

    var title: String {
        switch self {
        case .left: return "Left of"
        case .right: return "Right of"
        case .above: return "Above"
        }
    }

    /// Where the external screen's top-left corner goes, relative to the
    /// built-in screen's.
    func offset(builtin: CGSize, external: CGSize) -> CGPoint {
        switch self {
        case .left: return CGPoint(x: -external.width, y: builtin.height - external.height)
        case .right: return CGPoint(x: builtin.width, y: builtin.height - external.height)
        case .above: return CGPoint(x: ((builtin.width - external.width) / 2).rounded(), y: -external.height)
        }
    }
}

enum ScreenArrangement {
    /// The built-in and the external screen, if those are the only two.
    static func laptopAndExternal() -> (builtin: Display, external: Display)? {
        let displays = Display.all()
        guard displays.count == 2,
              let builtin = displays.first(where: \.isBuiltin),
              let external = displays.first(where: { !$0.isBuiltin }) else { return nil }
        return (builtin, external)
    }

    /// Which position the external screen is in now, if any of them.
    static func current(builtin: CGDirectDisplayID, external: CGDirectDisplayID) -> ScreenPosition? {
        let b = CGDisplayBounds(builtin), e = CGDisplayBounds(external)
        return ScreenPosition.allCases.first { position in
            let offset = position.offset(builtin: b.size, external: e.size)
            return abs(e.minX - b.minX - offset.x) < 1 && abs(e.minY - b.minY - offset.y) < 1
        }
    }

    /// Moves the external screen, keeping the main display (with the menu
    /// bar) at the origin. Saved like a change in System Settings.
    @discardableResult
    static func place(_ external: CGDirectDisplayID, _ position: ScreenPosition,
                      relativeTo builtin: CGDirectDisplayID) -> Bool {
        let offset = position.offset(builtin: CGDisplayBounds(builtin).size,
                                     external: CGDisplayBounds(external).size)
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        if CGDisplayIsMain(external) != 0 {
            CGConfigureDisplayOrigin(config, external, 0, 0)
            CGConfigureDisplayOrigin(config, builtin, Int32(-offset.x), Int32(-offset.y))
        } else {
            CGConfigureDisplayOrigin(config, builtin, 0, 0)
            CGConfigureDisplayOrigin(config, external, Int32(offset.x), Int32(offset.y))
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }
}
