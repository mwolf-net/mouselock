# Changelog

All notable changes to MouseLock are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/mwolf-net/mouselock/compare/v0.2.4...HEAD
[0.2.4]: https://github.com/mwolf-net/mouselock/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/mwolf-net/mouselock/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/mwolf-net/mouselock/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/mwolf-net/mouselock/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/mwolf-net/mouselock/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/mwolf-net/mouselock/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/mwolf-net/mouselock/releases/tag/v0.1.0
