import AppKit

/// The "About MouseLock" window: an overview plus what each menu option is for.
final class AboutWindow {
    private var window: NSWindow?

    func show() {
        if window == nil { window = makeWindow() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "About MouseLock"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 300)

        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: scrollView.bounds)
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.textStorage?.setAttributedString(Self.content())
        scrollView.documentView = textView

        window.contentView = scrollView
        return window
    }

    // MARK: Content

    private static func content() -> NSAttributedString {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let text = NSMutableAttributedString()
        func add(_ string: String, _ font: NSFont, color: NSColor = .labelColor, spacingAfter: CGFloat = 8) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = spacingAfter
            text.append(NSAttributedString(string: string + "\n", attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: style,
            ]))
        }
        func heading(_ string: String) {
            add(string, .boldSystemFont(ofSize: 15), spacingAfter: 6)
        }
        func paragraph(_ string: String) {
            add(string, .systemFont(ofSize: 13), spacingAfter: 12)
        }
        func option(_ name: String, _ explanation: String) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 10
            text.append(NSAttributedString(string: name + ": ", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
            ]))
            text.append(NSAttributedString(string: explanation + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
            ]))
        }

        add("MouseLock", .boldSystemFont(ofSize: 22), spacingAfter: 2)
        add("Version \(version)", .systemFont(ofSize: 12), color: .secondaryLabelColor, spacingAfter: 16)

        paragraph("""
            MouseLock helps you work with more than one screen. It snaps windows to a \
            grid, eases the pointer's way between screens, arranges your screens and \
            keeps the display awake right from the menu, lets someone use a touch \
            screen while you keep working on your own, and can lock the pointer onto \
            a second screen meant for someone else.
            """)

        heading("Windows")
        option("Window Grid (Ctrl+Option+Cmd+W)", """
            Divides each screen (minus menu bar and Dock) into roughly square cells. \
            When you resize a window, the edges you moved snap to the nearest cell \
            edges; a window you move lines up with them. Windows against an edge you \
            drag follow it, growing or shrinking, and windows you drag onto are \
            trimmed on the side that costs them least, or move into free space; \
            nothing further along changes. Outlines show all this while you drag. To \
            leave the other windows alone, overlapping them if need be, hold Control \
            once you've started dragging (held before, it makes a right-click). Press \
            Esc while dragging to call it off: the window goes back where it was when \
            you let go.
            """)
        paragraph("""
            A new window opens on the screen with the pointer. If there's free space, \
            it goes there at the size it opened at, rounded to whole cells, or as much \
            of that as fits, near the middle. If not, it opens at its smallest size, \
            at least one cell, on top, covering as little as possible of any one \
            window. Turning the grid on, or starting \
            MouseLock with it on, arranges all windows on the cells without \
            overlapping, each moving and resizing as little as possible, unless the \
            free space would leave one less than half its size.
            """)
        option("Window Grid Size", """
            How many cells: 6 along each screen's short side by default. Each choice \
            shows the resulting columns × rows on each screen.
            """)

        heading("Between Screens")
        option("Match Screen Edges", """
            When the pointer crosses between two screens side by side, it lands at \
            the same fraction of the height on the other screen, as if the screens' \
            corners touched. Without it macOS keeps the pointer at the same height in \
            points, which feels off with a Retina screen next to a lower resolution \
            one of about the same size. Not for screens above one another, nor when \
            more than one screen sits on that side.
            """)
        option("Wrap Pointer Around", """
            Pushing the pointer off the right side of the rightmost screen brings it \
            in on the left of the leftmost one, and the other way round, as if the \
            screens stood in a cylinder. It keeps its height (with Match Screen \
            Edges, the same fraction of the height). Also while dragging a window or \
            a file along, but not while resizing a window by its edge, nor while \
            locked.
            """)

        heading("Screen Settings")
        paragraph("Shortcuts for what System Settings can do too.")
        option("Position", """
            With more than one screen: puts a screen left of, right of or above \
            another, as in System Settings > Displays > Arrange. Options are listed \
            relative to the laptop's own screen first, or with the lid closed, to \
            the main display (the one with the menu bar). Screens side by side line \
            up their bottoms; a screen above another is centred on it. Handy when you \
            move between desks.
            """)
        option("Keep Display Awake", """
            Prevents display sleep, the screen saver and the idle password lock. \
            Always on while the pointer is locked. Resets when MouseLock restarts. It \
            only prevents sleep from inactivity: a laptop still goes to sleep when \
            you close the lid on battery power (keeping it running with the lid \
            closed needs the power adapter), or when the battery runs low. The menu \
            also shows what happens first when the Mac is left alone, or that the \
            display stays on anyway (because of your settings, or another app such \
            as a video playing).
            """)

        heading("Touchscreen")
        paragraph("""
            So someone can use a touch screen by touch while your own mouse and \
            keyboard carry on, on a separate touch screen or on a single shared one. \
            Touches are told apart from the mouse by the device they come from.
            """)
        option("Smart Touchscreen Mode (Ctrl+Option+Cmd+S)", """
            While unlocked: a tap clicks what's under the finger in one go, even in a \
            window that isn't active, and then keyboard focus goes back to where it \
            was. The pointer stays hidden where the finger was (so a menu the tap \
            opened stays open), and goes back to where you left it as soon as you use \
            the mouse; mouse and touch can be used interchangeably. To deliver a tap, \
            the app under the finger is activated for a moment. A tap in a password field keeps the \
            keyboard, so a PIN can be typed; click your own window to get it back.
            """)
        option("Touch Drag Scrolls", """
            Dragging one finger scrolls the page, as on a phone, instead of selecting \
            text. A tap still clicks; to select text or drag something, hold the \
            finger still for a moment before dragging. On by default when a USB \
            touch screen is connected.
            """)
        option("Touchscreen Adjust", """
            Puts touches where the finger is. macOS sometimes sends a touch screen's \
            taps to another screen, and doesn't rotate them when the screen is \
            rotated (System Settings > Displays > Rotation). Also makes two-finger \
            scrolling scroll under the fingers, and ignores pinch, which many touch \
            screens send as screen-zoom key presses. On by default when a USB touch \
            screen is connected.
            """)
        option("Touch Screen", """
            Which screen is the touch screen, where Touchscreen Adjust moves touches. \
            A touch screen's touch part is a separate USB device, so MouseLock can't tell which screen it is \
            by itself; a screen you pick is remembered whenever it's connected.
            """)

        heading("Lock")
        paragraph("""
            With an ordinary second screen meant for someone else, you can lock the \
            pointer onto it and hand them the mouse: they can use that screen, but \
            the mouse can't leave it. Only the keyboard unlocks: whoever has the \
            keyboard is in charge.
            """)
        option("Lock Pointer / Unlock Pointer (Ctrl+Option+Cmd+L)", """
            Moves the pointer onto the lock screen and keeps it there. Unlocking puts \
            it back where it was. Locking needs at least two screens. While locked, \
            this menu is disabled, so the mouse alone can't release the lock, and the \
            display is kept awake.
            """)
        option("Lock Options", "The submenu with the options below.")
        option("Lock Screen", """
            Your second screen: the one the pointer gets locked to. By default the \
            external screen on a laptop; a screen you pick is remembered whenever it's \
            connected.
            """)
        option("Hide Pointer When Locked", """
            Hides the pointer while locked, showing a brief crosshair where clicks \
            land. Meant for touch screens, so it's remembered per screen and starts \
            off for any new screen.
            """)
        option("Keep Dock Off Lock Screen", """
            While locked, keeps the pointer off the lock screen's bottom edge, so \
            pushing the mouse down can't pull the Dock onto it.
            """)
        option("Keep Menu Bar Hidden on Lock Screen", """
            While locked, keeps the pointer off the top few rows, so a hidden menu bar \
            (in full-screen apps) doesn't slide down.
            """)
        option("Block Right-Click and Extra Buttons While Locked", """
            While locked, ignores right-clicks and the middle and back/forward \
            buttons, so the mouse can't open context menus or navigate the browser \
            back. Also ignores a touch screen's two-finger tap (a right-click), in \
            Smart Touchscreen Mode too. Ctrl+click still works.
            """)

        heading("Other")
        option("Start at Login", "Starts MouseLock automatically when you log in.")

        heading("Tips")
        option("Mouse gestures", """
            Handing someone a Magic Mouse (or trackpad) while locked? Turn off the \
            gestures that switch between full-screen apps and Spaces (System \
            Settings > Mouse > More Gestures), or they can swipe the lock screen's \
            app away.
            """)
        option("Apps on your screen", """
            In Smart Touchscreen Mode, a tap briefly activates the app on the touch \
            screen, and macOS then brings all of that app's windows forward. So on \
            your own screen, either don't use that app at all, or use only that app \
            (say Chrome on both screens): then nothing jumps in front of your work.
            """)
        option("One app, full screen", """
            Give the lock or touch screen a single Space with just the one app, in \
            full screen. Any normal window gives access to Finder and other apps.
            """)
        option("Keyboard and USB", """
            Whoever has the keyboard can unlock, so keep it out of reach. The same \
            goes for the Mac's USB ports, and any USB port on the touch screen \
            itself: plugging in a keyboard bypasses all of this.
            """)
        option("Other ways out", """
            Consider turning off hot corners and Universal Control, and a Focus mode \
            so notifications don't pop up on the shared screen.
            """)
        option("Two-finger gestures", """
            With Touchscreen Adjust on, pinch does nothing and two-finger swiping \
            scrolls. Many touch screens start a two-finger gesture with a click where \
            the first finger lands, though, so begin a swipe on an empty spot, not on \
            a button.
            """)

        text.append(NSAttributedString(string: "\n"))
        let footer = NSMutableAttributedString(string: """
            Free software under the BSD 2-Clause License. Designed and tested by \
            Martin Wolf; code written by Claude (Anthropic).

            """, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
        let link = "https://github.com/mwolf-net/mouselock"
        footer.append(NSAttributedString(string: link, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .link: URL(string: link)!,
        ]))
        text.append(footer)
        return text
    }
}
