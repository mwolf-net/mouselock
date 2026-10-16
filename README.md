# MouseLock

A small menu bar app that keeps the mouse pointer on one display.

- The menu bar menu has a "Lock Screen" section for choosing the display the
  pointer gets locked to. By default that's the external display on a laptop;
  with no built-in display, it's the one the pointer isn't on when MouseLock
  starts.
- "Lock Pointer" / "Unlock Pointer" (or Ctrl+Opt+Cmd+L) toggles the lock.
  Locking moves the pointer onto the lock screen and keeps it there.
- Locking needs at least two screens. If the locked display is disconnected,
  the lock is released.
- While locked, the display is kept awake: no screen saver, no display
  sleep, and so no password lock from inactivity. "Keep Display Awake" in the
  menu does the same while unlocked.
- "Keep Dock Off Lock Screen" (on by default, remembered) keeps the pointer
  off the lock screen's bottom row while locked, so pushing down there can't
  make macOS move the Dock onto it.
- "Keep Menu Bar Hidden on Lock Screen" (on by default, remembered) likewise
  keeps the pointer off the top few rows, so a hidden menu bar (in full-screen
  apps, or with menu bar auto-hide) doesn't slide down. A menu bar that is
  always shown can still be clicked.
- "Hide Pointer While Locked" (remembered between launches) hides the pointer
  while locked, for touch screens. It relies on an undocumented macOS setting,
  so a future macOS may ignore it and leave the pointer visible.

## Build

Needs only the Command Line Tools (`xcode-select --install`), not Xcode.

    ./build.sh
    cp -R build/MouseLock.app ~/Applications/   # optional

## Permissions

Locking needs Accessibility permission (System Settings -> Privacy &
Security -> Accessibility). macOS asks the first time you lock.

The app is signed ad hoc, so macOS treats each rebuild as a new app. After
rebuilding, remove the old MouseLock entry from the Accessibility list (or
run `tccutil reset Accessibility com.martinwolf.mouselock`) and grant it
again.

To start it at login, add it under System Settings -> General -> Login Items.

## Debugging

Run it from a terminal with `MOUSELOCK_DEBUG=1` to log every time the pointer
is pushed back onto the locked display:

    MOUSELOCK_DEBUG=1 build/MouseLock.app/Contents/MacOS/MouseLock
