.PHONY: build app install run clean

# Debug build of the executable (not an app bundle).
build:
	swift build

# Universal, ad-hoc signed build/MouseLock.app.
app:
	scripts/build-app.sh

# Replace /Applications/MouseLock.app with a fresh build and (re)start it.
install: app
	-pkill -x MouseLock
	sleep 0.5
	rm -rf /Applications/MouseLock.app
	cp -R build/MouseLock.app /Applications/
	open /Applications/MouseLock.app

# Run the app from build/ with clamp logging on stderr.
run: app
	-pkill -x MouseLock
	MOUSELOCK_DEBUG=1 build/MouseLock.app/Contents/MacOS/MouseLock

clean:
	rm -rf .build build
