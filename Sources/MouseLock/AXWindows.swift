import ApplicationServices

// Accessibility helpers for other apps' windows, shared by smart touch and
// the window grid.

/// The app's Accessibility window with the given frame (global coordinates,
/// top left origin, as in the window list).
func axWindow(pid: pid_t, frame: CGRect) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return nil }
    return windows.first { window in
        guard let current = axFrame(window) else { return false }
        return abs(current.minX - frame.minX) < 2 && abs(current.minY - frame.minY) < 2
            && abs(current.width - frame.width) < 2 && abs(current.height - frame.height) < 2
    }
}

func axFrame(_ window: AXUIElement) -> CGRect? {
    guard let position = copyPoint(window, kAXPositionAttribute),
          let size = copySize(window, kAXSizeAttribute) else { return nil }
    return CGRect(origin: position, size: size)
}

/// Moves and resizes a window. Position first, then size, then position
/// again: an app may refuse a size that doesn't fit where the window was.
func setAXFrame(_ window: AXUIElement, _ frame: CGRect) {
    var position = frame.origin
    var size = frame.size
    guard let positionValue = AXValueCreate(.cgPoint, &position),
          let sizeValue = AXValueCreate(.cgSize, &size) else { return }
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
}

func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func copyPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
    var value: CFTypeRef?
    var point = CGPoint.zero
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXValueGetTypeID(),
          AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
    return point
}

func copySize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
    var value: CFTypeRef?
    var size = CGSize.zero
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXValueGetTypeID(),
          AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
    return size
}
