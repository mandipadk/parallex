# Default install prefix: Homebrew's (user-writable on Apple Silicon) when
# present, otherwise /usr/local — which is root-owned on modern macOS and
# needs `sudo make install`. Override with `make install PREFIX=~/.local`.
PREFIX ?= $(shell [ -w /opt/homebrew/bin ] && echo /opt/homebrew || echo /usr/local)
ARCH_FLAGS := --arch arm64 --arch x86_64
# Ask SwiftPM where universal products land — the location differs between
# toolchain versions, and a hardcoded path silently packages stale binaries.
RELEASE_DIR = $(shell swift build -c release $(ARCH_FLAGS) --show-bin-path)
APP_DIST := dist/Parallex.app

.PHONY: build test release install uninstall app app-install clean

build:
	swift build

test:
	swift test

# Universal (arm64 + x86_64) release binaries. The launcher built here is the
# one Parallex copies into every wrapper, so release wrappers run on both
# architectures.
release:
	swift build -c release $(ARCH_FLAGS)

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
	@echo "Installed $(PREFIX)/bin/parallex"

uninstall:
	rm -f "$(PREFIX)/bin/parallex" "$(PREFIX)/bin/parallex-launcher" "$(PREFIX)/bin/parallex-router"

# Assemble the GUI app bundle: GUI binary + embedded wrapper launcher + icon.
# The nested launcher is signed first so the outer app seal covers it.
app: release
	rm -rf "$(APP_DIST)"
	mkdir -p "$(APP_DIST)/Contents/MacOS" "$(APP_DIST)/Contents/Resources"
	cp Support/App-Info.plist "$(APP_DIST)/Contents/Info.plist"
	cp "$(RELEASE_DIR)/ParallexApp" "$(APP_DIST)/Contents/MacOS/Parallex"
	cp "$(RELEASE_DIR)/parallex-launcher" "$(APP_DIST)/Contents/Resources/parallex-launcher"
	cp "$(RELEASE_DIR)/parallex-router" "$(APP_DIST)/Contents/Resources/parallex-router"
	cp Sources/ParallexApp/Resources/AppIcon.icns "$(APP_DIST)/Contents/Resources/AppIcon.icns"
	codesign --force --sign - "$(APP_DIST)/Contents/Resources/parallex-launcher"
	codesign --force --sign - "$(APP_DIST)/Contents/Resources/parallex-router"
	codesign --force --sign - "$(APP_DIST)"
	@echo "Built $(APP_DIST)"

app-install: app
	rm -rf /Applications/Parallex.app
	ditto "$(APP_DIST)" /Applications/Parallex.app
	xattr -dr com.apple.quarantine /Applications/Parallex.app 2>/dev/null || true
	@echo "Installed /Applications/Parallex.app"

clean:
	swift package clean
	rm -rf dist
