.PHONY: build test app run install release sparkle-keys adapter clean

# Prefer full Xcode when installed (no need for `sudo xcode-select`).
ifneq ($(wildcard /Applications/Xcode.app/Contents/Developer),)
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
endif

SWIFT_FLAGS := --disable-keychain
APP_NAME := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleName" Resources/Info.plist)
APP_EXECUTABLE := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" Resources/Info.plist)

# Command Line Tools ship the Swift Testing macro plugin in a subfolder the
# compiler doesn't search by default; point at it when building with CLT only.
CLT_TESTING_PLUGINS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
ifeq ($(DEVELOPER_DIR),)
ifneq ($(wildcard $(CLT_TESTING_PLUGINS)),)
TEST_FLAGS := -Xswiftc -plugin-path -Xswiftc $(CLT_TESTING_PLUGINS)
endif
endif

build:
	swift build $(SWIFT_FLAGS)

test:
	swift test $(SWIFT_FLAGS) $(TEST_FLAGS)

# Debug build into ./build.
app:
	scripts/bundle.sh debug

run: app
	@pkill -x "$(APP_EXECUTABLE)" || true
	@sleep 1
	open "build/$(APP_NAME).app"

# Release build copied to /Applications.
install:
	scripts/bundle.sh release
	@pkill -x "$(APP_EXECUTABLE)" || true
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "build/$(APP_NAME).app" /Applications/
	open "/Applications/$(APP_NAME).app"

# make release VERSION=1.1.0   (PUBLISH=0 to build without pushing; see README → Releasing)
release:
	@test -n "$(VERSION)" || (echo "usage: make release VERSION=x.y.z" && exit 1)
	scripts/release.sh $(VERSION)

# Builds the now-playing helper into ./build (needed once for running from Xcode).
adapter:
	scripts/build-media-adapter.sh build
	codesign --force --sign - build/MediaRemoteAdapter.framework

sparkle-keys:
	scripts/sparkle-keys.sh

clean:
	rm -rf .build build
