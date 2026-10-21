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
            MouseLock helps when a second screen is meant for someone else, such as \
            customers or guests using a web app, while you keep working on your own \
            screen. It works in one of two ways:
            """)
        paragraph("""
            Lock: the mouse pointer is locked onto the second screen (the lock screen), \
            so the mouse can't leave it. With an ordinary second screen, you can hand \
            someone the mouse and let them use that screen safely; when you take the \
            mouse back, unlock with the keyboard shortcut Ctrl+Option+Cmd+L. Only the \
            keyboard unlocks: whoever has the keyboard is in charge.
            """)
        paragraph("""
            Smart touch: if the second screen is a touch screen, people can use it by \
            touch while your own mouse and keyboard stay on your screen, without \
            locking anything.
            """)

        heading("Lock")
        option("Lock Screen", """
            Your second screen: the one the pointer gets locked to. If it's a touch \
            screen, the touch screen options below apply to it as well. By default the \
            external screen on a laptop; a screen you pick is remembered whenever it's \
            connected.
            """)
        option("Lock Pointer / Unlock Pointer (Ctrl+Option+Cmd+L)", """
            Moves the pointer onto the lock screen and keeps it there. Unlocking puts \
            it back where it was. Locking needs at least two screens. While locked, \
            this menu is disabled, so the mouse alone can't release the lock, and the \
            display is kept awake.
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

        heading("Touchscreen")
        option("Smart Touchscreen Mode", """
            While unlocked: a tap on the touch screen clicks what's under the finger \
            in one go, even in a window that isn't active, and then keyboard focus \
            returns to your screen. Your mouse can't wander onto the touch screen, and \
            the pointer stays hidden there; it returns to where it was as soon as you \
            move the mouse. To deliver a tap, the app on the touch screen is activated \
            for a moment. A tap in a password field keeps the keyboard, so a PIN can \
            be typed; click your own window to get it back.
            """)
        option("Touch Drag Scrolls", """
            Dragging one finger scrolls the page, as on a phone, instead of selecting \
            text. A tap still clicks; to select text or drag something, hold the \
            finger still for a moment before dragging. On by default when a USB \
            touch screen is connected.
            """)
        option("Touchscreen Adjust", """
            Puts touches where the finger is. macOS sometimes sends a touch screen's \
            taps to the main display, and doesn't rotate them when the screen is \
            rotated (System Settings > Displays > Rotation). Also makes two-finger \
            scrolling scroll under the fingers, and ignores pinch, which many touch \
            screens send as screen-zoom key presses. On by default when a USB touch \
            screen is connected.
            """)

        heading("Other")
        option("Keep Display Awake", """
            Prevents display sleep, the screen saver and the idle password lock, \
            without locking the pointer. Always on while locked. Resets when \
            MouseLock restarts. It only prevents sleep from inactivity: a laptop \
            still goes to sleep when you close the lid on battery power (keeping it \
            running with the lid closed needs the power adapter), or when the battery \
            runs low.
            """)
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
