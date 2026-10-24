# Changelog

All notable changes to MouseLock are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Touch Screen menu: a None choice, the default when no USB touch screen is
  connected; with a single screen it isn't shown at all.

## [0.10.1] - 2026-10-24

### Changed

- Window Grid: a new window gets at least a usable size, about 480×360
  points in whole cells (unless it opened smaller or the app needs more),
  instead of a single cell, which can be tiny with small cells.

## [0.10.0] - 2026-10-24

### Added

- Window Grid: when a screen is disconnected, the remaining screen shows its
  own windows again (macOS switches to the departed screen's Space), the
  departed screen's windows that would clutter it are minimized, and a
  brief message says so. When the screen is reconnected, they go back where
  they were.

### Changed

- Window Grid: holding Control while dragging a window still snaps it to the
  cells, but leaves other windows alone, overlapping them if need be.
  (Before, it skipped the cells too.)

## [0.9.3] - 2026-10-24

### Fixed

- Turning off MouseLock's Accessibility permission while it ran froze the
  mouse and keyboard for the whole session (login screen included) until a
  restart: macOS kept passing all input through MouseLock's event taps and
  then dropped it. MouseLock now removes its taps the moment the permission
  goes, and sets them up again when it's back. A change macOS doesn't
  announce is caught within a minute, with a message explaining what
  happened.

## [0.9.2] - 2026-10-24

### Fixed

- Window Grid: a window being pushed by one you enlarge, but that can't get
  any smaller (such as System Settings), no longer ends up partly off the
  screen; it stays where it was, overlapped.

## [0.9.1] - 2026-10-23

### Fixed

- Window Grid: a window that should make room for one you drag, but can't
  get small enough (an app's minimum size), keeps its size instead of
  shrinking as far as it can and overlapping anyway.

## [0.9.0] - 2026-10-23

### Changed

- Smart Touchscreen Mode and Touch Drag Scrolls tell touches from the
  mouse by the device they come from, wherever they land, so they're plain
  on/off settings (no longer per screen) and work on a single shared
  screen too. Settings carry over.
- The touch screen is chosen on its own, under Touch Screen in the menu,
  instead of being the lock screen. It's only needed for Touchscreen
  Adjust.
- Smart Touchscreen Mode no longer keeps the mouse off the touch screen:
  mouse and touch can be used interchangeably. After a tap the pointer
  stays hidden where the finger was, and goes back to where you left it as
  soon as you use the mouse.
- Lock Pointer names the lock screen ("Lock Pointer to …"), and while locked
  "Unlock Pointer (from …)".

### Fixed

- Touchscreen Adjust: with the touch screen as the main display (say a
  laptop with its lid closed), macOS could send touches to another screen,
  and they stayed there.

## [0.8.1] - 2026-10-23

### Changed

- Window Grid: 6 cells along each screen's short side by default (was 4),
  unless you picked a size. Window Grid Size names each screen.
- Window Grid: a new window that fits into free space gets the size it
  opened at (rounded to whole cells), or as much of it as fits, instead of
  its smallest size.

### Fixed

- Window Grid: a new tab in Terminal or Finder (which macOS makes a window
  of its own) no longer shrinks and moves the window it's a tab of.

## [0.8.0] - 2026-10-23

### Added

- Wrap Pointer Around: pushing the pointer off the right side of the
  rightmost screen brings it in on the left of the leftmost one, and the
  other way round. Also while dragging a window or a file, but not while
  resizing a window by its edge.

### Changed

- The menu is reordered: Window Grid first, then the pointer between
  screens, screen positioning and Keep Display Awake, the touchscreen
  options, and Lock Pointer last, with the lock screen and the options for
  while locked in a Lock Options submenu. The About window and README
  follow the same order.

### Fixed

- A mouse button could stay down for good if a press MouseLock passed on
  never got its release (say the touch screen unplugged mid-touch), so
  clicks stopped working. MouseLock now releases its own presses once no
  device holds the button, and releases a touch screen press with no touch
  input at all for 15 seconds.
- Quitting MouseLock with `kill` (or `pkill`) now quits it properly,
  showing the pointer again and releasing any press it posted.

## [0.7.0] - 2026-10-23

### Added

- Window Grid: a new window opens straight onto the grid at its smallest
  size (at least one cell), on the screen with the pointer: in free space
  near the middle, or else on top, covering as little as possible of any
  one window. It never pushes other windows aside.
- Window Grid: dragging pushes and pulls only the windows directly
  involved. Windows against an edge you drag follow it, growing or
  shrinking; windows you drag onto are trimmed on the side that costs them
  least area, or move into free space.
- Window Grid: the preview also outlines where other windows will go.
- Window Grid: hold Control once you've started dragging to skip snapping
  and pushing, or press Esc to put the window back where it was when you
  let go.

### Fixed

- Window Grid: a click no longer counts as a drag when the app changes its
  window's frame meanwhile.

## [0.6.0] - 2026-10-23

### Added

- Window Grid (Ctrl+Option+Cmd+W): each screen is divided into roughly
  square cells (4 along its short side, or as chosen under Window Grid
  Size), and a window you resize or move snaps to them, with an outline
  showing where while you drag. Turning it on, or starting with it on,
  arranges all windows on the cells without overlapping, each moving and
  resizing as little as possible.

## [0.5.0] - 2026-10-23

### Added

- Match Screen Edges: the pointer crosses between screens side by side at
  the same fraction of their height, as if their corners touched, instead
  of at the same height in points.

### Fixed

- Screen positioning: a screen above another that's narrower than it could
  overlap a taller screen next to it, or the screen above that one. It now
  moves sideways (or up) to a free spot.

## [0.4.1] - 2026-10-22

### Changed

- Screen positioning also works without a built-in screen (a laptop with
  its lid closed, or a desktop Mac): options are then relative to the main
  display first.

## [0.4.0] - 2026-10-22

### Added

- Ctrl+Option+Cmd+S turns Smart Touchscreen Mode on or off, with a brief
  popup saying which.
- The Keep Display Awake menu item shows what happens first when the Mac is
  left alone, such as "display off after 10 min", or that a laptop with its
  lid closed on battery will sleep ("clamshell"), or that the display stays
  on anyway (because of your settings, or another app such as a video
  playing).

## [0.3.0] - 2026-10-22

### Added

- On a laptop with external screens, a menu to put each external screen
  left of, right of or above another screen, as in System Settings >
  Displays > Arrange. Screens side by side line up their bottoms; a screen
  above another is centred on it.

## [0.2.8] - 2026-10-22

### Changed

- Touch Drag Scrolls is now on by default when a USB touch screen is
  connected, like Touchscreen Adjust. Screens where it was already turned on
  keep it.
- Smart Touchscreen Mode: a tap in a password field now keeps the keyboard,
  so a PIN can be typed on the touch screen. Click your own window to get it
  back.
- The About window's tip on two-finger gestures now says what Touchscreen
  Adjust does with them.

### Fixed

- Smart Touchscreen Mode: after a tap that put a password field in focus
  (such as a button opening a PIN dialog), keyboard focus could stay on the
  touch screen although your own app was in front, and the browser kept
  secure input on, blocking keyboard tools. MouseLock now checks that focus
  really went back, and tries again if not.

## [0.2.7] - 2026-10-21

### Added

- A Tips section in the About window: mouse gestures to turn off, which apps
  to use on your own screen with Smart Touchscreen Mode, and ways to keep
  the shared screen safe.

## [0.2.6] - 2026-10-21

### Fixed

- After an update, MouseLock could silently do nothing: macOS treats each
  new build as a new app, so the Accessibility permission of the previous
  version no longer applied, while the menu still showed options as on.
  Now MouseLock removes the stale permission entry and asks again on the
  first launch of a new version, shows a warning icon and an "Accessibility
  Permission Needed" menu item while the permission is missing, and starts
  working as soon as it's granted, without a restart.

## [0.2.5] - 2026-10-21

### Changed

- About window: the lock screen is described as your second screen (not
  necessarily a touch screen), with the hand-over-the-mouse use of the lock;
  Keep Display Awake notes that a laptop still sleeps when its lid is closed
  on battery power.

## [0.2.4] - 2026-10-21

### Added

- "About MouseLock..." in the menu: an overview, plus what each option is
  for.

## [0.2.3] - 2026-10-21

### Added

- Two-finger gestures on a touch screen (which many touch screens send as
  mouse and keyboard input): two-finger scrolling now scrolls where the
  fingers are, with the page following them, instead of at the screen's
  corner; pinch, sent as screen-zoom key presses, is ignored. Part of
  Touchscreen Adjust.
- The touch screen's two-finger tap (a right-click) is blocked along with
  other right-clicks, now also in Smart Touchscreen Mode.

### Fixed

- Smart Touchscreen Mode handled each tap twice when Touch Drag Scrolls was
  also on, switching focus more than needed.

## [0.2.2] - 2026-10-20

### Added

- Touchscreen Adjust also handles a rotated touch screen: macOS rotates the
  picture but not the touches, so MouseLock applies the display's rotation
  (System Settings -> Displays -> Rotation) to them. Measured at 90 degrees.

## [0.2.1] - 2026-10-20

### Changed

- The menu is organised into sections: lock (with the lock screen choice),
  touchscreen, and Keep Display Awake.
- Smart Touchscreen Mode leaves the pointer (hidden) on the touch screen
  after a tap, so hover effects such as drop-down menus stay open; it goes
  back as soon as the mouse moves.

### Fixed

- With Touch Drag Scrolls and Smart Touchscreen Mode both on, taps were
  held back twice, delaying the click.

## [0.2.0] - 2026-10-20

### Added

- Smart Touchscreen Mode: while unlocked, a tap on the lock screen clicks
  the window under it in one go (even if inactive), then returns the
  pointer and keyboard focus to where they were on the other screen. The
  mouse is kept off the touch screen (when a USB touch screen is detected)
  and the pointer is hidden there.
- Touch Drag Scrolls: a one-finger drag on the touch screen scrolls instead
  of selecting text; press and hold briefly first to drag as usual.
- Touchscreen Adjust: moves touches that macOS sent to the main display onto
  the lock screen, keeping their relative position. On by default when a USB
  touch screen is connected; can be switched per screen.
- Tooltips explaining each menu item.

## [0.1.1] - 2026-10-17

### Added

- Homebrew cask: `brew install --cask mwolf-net/tap/mouselock`. The release
  workflow keeps it up to date.

### Changed

- The "Hide Pointer on <screen>" menu item is now "Hide Pointer When
  Locked". It's still remembered per screen.

## [0.1.0] - 2026-10-17

First public release.

### Added

- Menu bar app that locks the mouse pointer to one display, toggled with
  Ctrl+Opt+Cmd+L or from the menu.
- Lock screen choice in the menu, with a sensible default (the external
  display on a laptop) and remembered across reboots.
- Pointer returns to where it was when unlocking.
- Display kept awake while locked (no screen saver, display sleep or idle
  password lock); "Keep Display Awake" toggle for use without the lock.
- Options for kiosk-style use: hide the pointer (with a crosshair shown on
  clicks; set per screen, for touch screens), keep the Dock and a hidden
  menu bar off the lock screen, and block right-clicks and extra mouse
  buttons.
- While locked, the menu is disabled so only the keyboard can unlock.
- Start at Login.

[Unreleased]: https://github.com/mwolf-net/mouselock/compare/v0.10.1...HEAD
[0.10.1]: https://github.com/mwolf-net/mouselock/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/mwolf-net/mouselock/compare/v0.9.3...v0.10.0
[0.9.3]: https://github.com/mwolf-net/mouselock/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/mwolf-net/mouselock/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/mwolf-net/mouselock/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/mwolf-net/mouselock/compare/v0.8.1...v0.9.0
[0.8.1]: https://github.com/mwolf-net/mouselock/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/mwolf-net/mouselock/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/mwolf-net/mouselock/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/mwolf-net/mouselock/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/mwolf-net/mouselock/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/mwolf-net/mouselock/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/mwolf-net/mouselock/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/mwolf-net/mouselock/compare/v0.2.8...v0.3.0
[0.2.8]: https://github.com/mwolf-net/mouselock/compare/v0.2.7...v0.2.8
[0.2.7]: https://github.com/mwolf-net/mouselock/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/mwolf-net/mouselock/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/mwolf-net/mouselock/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/mwolf-net/mouselock/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/mwolf-net/mouselock/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/mwolf-net/mouselock/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/mwolf-net/mouselock/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/mwolf-net/mouselock/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/mwolf-net/mouselock/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/mwolf-net/mouselock/releases/tag/v0.1.0
