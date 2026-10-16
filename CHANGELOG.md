# Changelog

All notable changes to MouseLock are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
  clicks), keep the Dock and a hidden menu bar off the lock screen, and block
  right-clicks and extra mouse buttons.
- While locked, the menu is disabled so only the keyboard can unlock.
- Start at Login.
