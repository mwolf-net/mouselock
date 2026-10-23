# MouseLock

A small macOS menu bar app that locks the mouse pointer to one display.

Press a hotkey and the pointer moves to your second screen and stays there:
moving the mouse can't bring it back to the first one. Press the hotkey again
to unlock. That makes the second screen work like a kiosk (say, a web app in a
full-screen browser for customers or guests) while you keep the laptop screen
and the keyboard for yourself.

If the second screen is a touch screen, there's an even simpler setup: in
Smart Touchscreen Mode your mouse stays on your screen, while someone else
uses the touch screen by tapping and scrolling, without disturbing your
pointer or keyboard focus.

Why not Chrome's `--kiosk` mode? It's great for a dedicated machine, but it
needs a browser instance of its own, so it can't share a profile (logins,
local storage) with the normal browser window on your laptop screen. It also
doesn't stop the mouse from wandering onto your screen, and it only covers
Chrome. MouseLock works with any app, and you switch it on and off with a
hotkey instead of restarting the browser.

## Features

- **Lock the pointer** to one screen with Ctrl+Opt+Cmd+L or from the menu.
  Unlocking puts the pointer back where it was.
- **Only the keyboard unlocks.** While locked, MouseLock's menu is greyed
  out (Quit included), so the mouse alone can't release the lock.
- **Keeps the display awake** while locked: no screen saver, no display sleep,
  and so no idle password lock. Can also be turned on without locking.
- **Kiosk-friendly options** (all on by default, except hiding the pointer):
  - Keep the Dock from moving onto the lock screen.
  - Keep a hidden menu bar (full-screen apps, or auto-hide) from sliding down.
  - Block right-clicks and extra mouse buttons (middle, back/forward),
    including a touch screen's two-finger tap (also in Smart Touchscreen
    Mode).
  - Hide the pointer, showing a brief crosshair where clicks land. Meant for
    touch screens, so it's set per screen and starts off for a new one.
- **Touch screen support** for a touch screen as the lock screen:
  - **Smart Touchscreen Mode** (Ctrl+Opt+Cmd+S): while unlocked, a tap on
    the touch screen clicks what's under the finger (in one tap, even in an
    inactive window), then the pointer and keyboard focus go straight back
    to where they were. The mouse can't enter the touch screen, and the
    pointer stays hidden there. Someone can use the touch screen while you
    keep working on yours.
    A tap in a password field keeps the keyboard, so a PIN can be typed;
    click your own window to get it back.
  - **Touch Drag Scrolls**: dragging a finger scrolls instead of selecting
    text. A tap still clicks; holding the finger still for a moment before
    dragging selects or drags as usual. On by default when a USB touch
    screen is connected.
  - **Touchscreen Adjust**: macOS sometimes sends a touch screen's taps to
    the main display instead, and doesn't rotate them when the screen is
    rotated (System Settings -> Displays -> Rotation, say for a portrait
    wall mount). MouseLock puts them where the finger is. Many touch screens
    also turn two-finger gestures into mouse and keyboard input: MouseLock
    makes two-finger scrolling scroll under the fingers (the page following
    them), and ignores pinch, which arrives as screen-zoom key presses. On by
    default when a USB touch screen is connected.
- **Sensible default lock screen:** the external display on a laptop, or the
  screen the pointer isn't on when MouseLock starts. A screen picked in the
  menu is remembered.
- **Position screens** left of, right of or above another screen from the
  menu, instead of dragging them around in System Settings -> Displays ->
  Arrange. Relative to the laptop's own screen first, or with the lid
  closed (or on a desktop Mac), to the main display.
- **Match Screen Edges**: the pointer crosses between screens side by side
  at the same fraction of their height, as if their corners touched. Handy
  for a Retina screen next to a lower resolution one of about the same size.
- **Window Grid** (Ctrl+Opt+Cmd+W): divides each screen into roughly square
  cells, 8 along its short side, and snaps a window you resize or move to
  them, with an outline showing where while you drag.
  Turning it on snaps all windows on screen to the cells, moving and
  resizing each as little as possible.
- Start at login. No Dock icon, no windows, no network access.

## Requirements

macOS 13 (Ventura) or later, on Apple silicon or Intel.

## Installation

### Homebrew

    brew install --cask mwolf-net/tap/mouselock

MouseLock isn't notarized by Apple (that needs a paid developer account), so
macOS blocks its first launch: open it once, click Done, then go to System
Settings -> Privacy & Security and click "Open Anyway". Homebrew keeps that
approval when upgrading (`brew upgrade --cask mouselock`).

### Download

1. Download `MouseLock-<version>.zip` from the
   [latest release](https://github.com/mwolf-net/mouselock/releases/latest),
   unzip it and move `MouseLock.app` to Applications.
2. MouseLock isn't notarized by Apple (that needs a paid developer account),
   so macOS blocks it the first time. Open it, click Done, then go to System
   Settings -> Privacy & Security and click "Open Anyway". Or run:

       xattr -dr com.apple.quarantine /Applications/MouseLock.app

3. Tick "Start at Login" in its menu to have it start automatically.

### Build from source

You only need the Command Line Tools (`xcode-select --install`), not Xcode.

    git clone https://github.com/mwolf-net/mouselock.git
    cd mouselock
    make install

That builds `build/MouseLock.app`, copies it to `/Applications` and starts it.
Tick "Start at Login" in its menu to have it start automatically.

### Accessibility permission

MouseLock needs Accessibility permission to see and adjust mouse and touch
input. When it's missing, macOS asks at startup; allow MouseLock under System
Settings -> Privacy & Security -> Accessibility. MouseLock picks the
permission up by itself, no restart needed. Until then, its menu bar icon
shows a warning sign and the menu has an "Accessibility Permission Needed"
item that opens the right settings page.

The app is signed ad hoc (not with an Apple developer certificate), so macOS
treats each new build as a new app, and the entry left over from the
previous version no longer applies. After an update, MouseLock removes that
stale entry itself and asks again, so you only need to allow it. (Manually:
`tccutil reset Accessibility net.mwolf.mouselock`.)

## Usage

Click the pointer icon in the menu bar:

- **Lock Screen**: the display the pointer gets locked to.
- **Lock Pointer / Unlock Pointer** (Ctrl+Opt+Cmd+L): toggles the lock.
  Locking needs at least two screens.
- **Smart Touchscreen Mode** (Ctrl+Opt+Cmd+S): toggles it for the lock
  screen.
- **Keep Display Awake**: keeps the display awake without locking (it always
  is while locked). The menu also shows what happens first when idle,
  such as "display off after 10 min", or that the display stays on anyway. Resets when MouseLock restarts. It only prevents sleep
  from inactivity: a laptop still sleeps when its lid is closed on battery
  power (running with the lid closed needs the power adapter), or when the
  battery runs low.
- The remaining options are described under Features and remembered between
  launches.

The menu bar icon shows the state: a pointer when idle, a lock while locked,
and a coffee cup while keeping the display awake without a lock.

If the lock screen is disconnected, the lock is released. If another screen
goes away (for example, closing the lid in clamshell mode), the lock stays on.

## Tips for kiosk setups

MouseLock limits what the mouse can do, but macOS and browsers offer a few
more ways out. Worth checking:

- Keep the app on the lock screen in full screen. Any normal window gives the
  mouse access to Finder, other apps and so on.
- Give the lock screen a single Space with just that one app, so there's
  nothing to switch to. Also turn off Magic Mouse and trackpad gestures that
  switch Spaces or full-screen apps (System Settings -> Mouse / Trackpad ->
  More Gestures).
- In Smart Touchscreen Mode, a tap briefly activates the app on the touch
  screen, which brings all of that app's windows forward. So on your own
  screen, either don't use that app, or use only that app (say Chrome on
  both screens), so nothing jumps in front of your work.
- Turn off hot corners and Universal Control if you don't use them, and
  consider a Focus mode so notifications don't pop up on the lock screen.
- In the web app: prevent swipe-back navigation with
  `overscroll-behavior-x: none`, and block `contextmenu`, `dragover`/`drop`
  and Ctrl+wheel (pinch zoom).
- Keep the keyboard out of reach: whoever has it can unlock MouseLock, leave
  full screen and so on. Likewise the Mac's USB ports, since plugging in a
  keyboard (or anything else) bypasses all of this.

## How it works

- The lock is a Quartz event tap on mouse events. When the pointer would leave
  the lock screen, MouseLock moves it back to the edge.
- The hotkey is registered with `RegisterEventHotKey`, so it works whatever
  app is in front.
- Keeping the display awake uses a standard power assertion
  (`PreventUserIdleDisplaySleep`); check it with `pmset -g assertions`.
- A few refinements use undocumented CoreGraphics calls: hiding the pointer
  while another app is in front, and turning off the short input pause macOS
  adds after the pointer is moved programmatically. They're all in
  [`PrivateAPI.swift`](Sources/MouseLock/PrivateAPI.swift). If a future macOS
  drops them, those refinements stop working but the lock itself doesn't.

## Development

    make build     # debug build of the executable (swift build)
    make app       # universal build/MouseLock.app
    make run       # build and run from build/, logging clamps to stderr
    make install   # build, install to /Applications and restart
    make clean

`make run` sets `MOUSELOCK_DEBUG=1`, which logs every time the pointer is
pushed back onto the lock screen. Run from a terminal, MouseLock uses the
terminal app's Accessibility permission rather than its own.

The code is a Swift package with one executable target, one file per
component, in [`Sources/MouseLock`](Sources/MouseLock).

### Releasing

1. Set the new version in `Support/Info.plist` (`CFBundleShortVersionString`
   and `CFBundleVersion`) and move the changelog's Unreleased entries under a
   new version heading.
2. Commit, then tag and push: `git tag v1.2.3 && git push origin main v1.2.3`.

The Release workflow checks the tag matches `Info.plist`, builds the app and
publishes a GitHub release with the zip, its SHA-256 checksum, and the
changelog section as release notes. It then updates the cask in
[mwolf-net/homebrew-tap](https://github.com/mwolf-net/homebrew-tap), using
a deploy key stored as the `HOMEBREW_TAP_DEPLOY_KEY` secret.

## License

BSD 2-Clause; see [LICENSE](LICENSE). Have fun with it.

## Acknowledgments

MouseLock was designed and tested by Martin Wolf. All of the code and this
README were written by [Claude](https://claude.com/claude-code) (Anthropic's
Claude Opus 5.5, via Claude Code), including the experiments that tuned the
edge handling.
