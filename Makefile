# Default install prefix: Homebrew's (user-writable on Apple Silicon) when
# present, otherwise /usr/local — which is root-owned on modern macOS and
# needs `sudo make install`. Override with `make install PREFIX=~/.local`.
PREFIX ?= $(shell [ -w /opt/homebrew/bin ] && echo /opt/homebrew || echo /usr/local)
ARCH_FLAGS := --arch arm64 --arch x86_64
# Parallex keeps the classic window layout (a full-height sidebar, not
# macOS 26's floating one) and draws its own frosted background; Info.plist
# opts out of the new window chrome (UIDesignRequiresCompatibility).
LINK_FLAGS :=
# Ask SwiftPM where universal products land — the location differs between
# toolchain versions, and a hardcoded path silently packages stale binaries.
RELEASE_DIR = $(shell swift build -c release $(ARCH_FLAGS) --show-bin-path)
APP_DIST := dist/Parallex.app
# The version lives in one place (ParallexConfig.version); the app bundle and
# release artifacts take it from there.
VERSION := $(shell sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/ParallexKit/ParallexConfig.swift)
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
ZIP := dist/Parallex-$(VERSION).zip
DMG := dist/Parallex.dmg
NOTES ?= dist/release-notes.md

.PHONY: build test bench release install uninstall app app-install dist publish icon clean

build:
	swift build $(LINK_FLAGS)

test:
	swift test

# Time what the launcher adds before an app starts (budget: 50 ms).
bench: build
	Support/bench-launch.sh

# Universal (arm64 + x86_64) release binaries. The launcher built here is the
# one Parallex copies into every wrapper, so release wrappers run on both
# architectures.
release:
	swift build -c release $(ARCH_FLAGS) $(LINK_FLAGS)

install: release
	@if [ ! -w "$(PREFIX)/bin" ] && { [ -e "$(PREFIX)/bin" ] || [ ! -w "$(PREFIX)" ]; }; then \
		echo "error: $(PREFIX)/bin is not writable. Either:"; \
		echo "  sudo make install"; \
		echo "  make install PREFIX=/opt/homebrew    # if you use Homebrew"; \
		echo "  make install PREFIX=~/.local         # then ensure ~/.local/bin is on PATH"; \
		exit 1; \
	fi
	install -d "$(PREFIX)/bin"
	install "$(RELEASE_DIR)/parallex" "$(PREFIX)/bin/parallex"
	install "$(RELEASE_DIR)/parallex-launcher" "$(PREFIX)/bin/parallex-launcher"
	install "$(RELEASE_DIR)/parallex-router" "$(PREFIX)/bin/parallex-router"
	install -d "$(PREFIX)/libexec"
	install -m 644 "$(RELEASE_DIR)/libparallexhome.dylib" "$(PREFIX)/libexec/libparallexhome.dylib"
	install -m 644 "$(RELEASE_DIR)/libparallexgroups.dylib" "$(PREFIX)/libexec/libparallexgroups.dylib"
	@echo "Installed $(PREFIX)/bin/parallex"

uninstall:
	rm -f "$(PREFIX)/bin/parallex" "$(PREFIX)/bin/parallex-launcher" "$(PREFIX)/bin/parallex-router" \
		"$(PREFIX)/libexec/libparallexhome.dylib" "$(PREFIX)/libexec/libparallexgroups.dylib"

# Assemble the GUI app bundle: GUI binary, the embedded wrapper launcher,
# link router and `parallex` command, and the icon. Nested binaries are
# signed first so the outer app seal covers them.
app: release
	rm -rf "$(APP_DIST)"
	mkdir -p "$(APP_DIST)/Contents/MacOS" "$(APP_DIST)/Contents/Resources"
	cp Support/App-Info.plist "$(APP_DIST)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
		-c "Set :CFBundleVersion $(BUILD_NUMBER)" "$(APP_DIST)/Contents/Info.plist"
	cp "$(RELEASE_DIR)/ParallexApp" "$(APP_DIST)/Contents/MacOS/Parallex"
	cp "$(RELEASE_DIR)/parallex-launcher" "$(APP_DIST)/Contents/Resources/parallex-launcher"
	cp "$(RELEASE_DIR)/parallex-router" "$(APP_DIST)/Contents/Resources/parallex-router"
	cp "$(RELEASE_DIR)/parallex" "$(APP_DIST)/Contents/Resources/parallex"
	cp "$(RELEASE_DIR)/libparallexhome.dylib" "$(APP_DIST)/Contents/Resources/libparallexhome.dylib"
	cp "$(RELEASE_DIR)/libparallexgroups.dylib" "$(APP_DIST)/Contents/Resources/libparallexgroups.dylib"
	cp Sources/ParallexApp/Resources/AppIcon.icns "$(APP_DIST)/Contents/Resources/AppIcon.icns"
	codesign --force --sign - "$(APP_DIST)/Contents/Resources/parallex-launcher"
	codesign --force --sign - "$(APP_DIST)/Contents/Resources/parallex-router"
	codesign --force --sign - "$(APP_DIST)/Contents/Resources/parallex"
	codesign --force --sign - "$(APP_DIST)/Contents/Resources/libparallexhome.dylib"
	codesign --force --sign - "$(APP_DIST)/Contents/Resources/libparallexgroups.dylib"
	codesign --force --sign - "$(APP_DIST)"
	@echo "Built $(APP_DIST) $(VERSION) ($(BUILD_NUMBER))"

app-install: app
	rm -rf /Applications/Parallex.app
	ditto "$(APP_DIST)" /Applications/Parallex.app
	xattr -dr com.apple.quarantine /Applications/Parallex.app 2>/dev/null || true
	@echo "Installed /Applications/Parallex.app"

# Release artifacts: the signed zip the in-app updater installs, its
# signature (made with the release key in the login keychain), and a DMG for
# downloading from the website.
dist: app
	rm -f "$(ZIP)" "$(ZIP).sig" "$(DMG)"
	ditto -c -k --sequesterRsrc --keepParent "$(APP_DIST)" "$(ZIP)"
	swift Support/release-key.swift sign "$(ZIP)" > "$(ZIP).sig"
	Support/make-dmg.sh "$(APP_DIST)" "$(DMG)"
	@echo "Built $(ZIP), $(ZIP).sig and $(DMG)"

# Publish a GitHub release for the current version with the notes in $(NOTES).
publish: dist
	@test -s "$(NOTES)" || { echo "error: write the release notes to $(NOTES) first"; exit 1; }
	@test -z "$$(git status --porcelain -- Sources launcher Package.swift)" || { echo "error: commit your changes first"; exit 1; }
	gh release create "v$(VERSION)" "$(ZIP)" "$(ZIP).sig" "$(DMG)" --target "$$(git rev-parse HEAD)" \
		--title "Parallex $(VERSION)" --notes-file "$(NOTES)"

# Regenerate the app icon from its source (Support/make-app-icon.swift).
icon:
	swift Support/make-app-icon.swift Sources/ParallexApp/Resources/AppIcon.icns

clean:
	swift package clean
	rm -rf dist
