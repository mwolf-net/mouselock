import AppKit

/// A brief message near the bottom of the screen with the pointer, like the
/// volume popup: no focus, no clicks, gone after a moment.
final class Toast {
    private static let duration: TimeInterval = 1.2

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    func show(_ message: String, for duration: TimeInterval = Toast.duration) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        label.stringValue = message
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 40, height: label.frame.height + 24)
        label.setFrameOrigin(NSPoint(x: 20, y: 12))

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.12,
                                  width: size.width, height: size.height), display: true)
        }
        hideWork?.cancel()
        // Animated, so it takes over from a fade-out still running.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                panel?.animator().alphaValue = 0
            }, completionHandler: {
                // Unless shown again meanwhile.
                if panel?.alphaValue == 0 { panel?.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        panel.contentView = background

        label.font = .systemFont(ofSize: 15, weight: .medium)
        background.addSubview(label)
        return panel
    }
}
