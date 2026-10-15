# MouseLock

A small menu bar app that keeps the mouse pointer on one display.

- Menu bar icon -> "Lock to <display>": moves the pointer onto that display
  and keeps it there.
- Ctrl+Opt+Cmd+L toggles the lock. When locking, it uses the display you
  locked to last, or else the first external display.
- If the locked display is disconnected, the lock is released.

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
