# RideCPP — lightweight C++ IDE for macOS
#
# Common workflows:
#   make build     build the app (Release-free Debug build, ad-hoc signed)
#   make run       build and launch the app
#   make install   install RideCPP.app into /Applications and launch it
#   make dist      build a signed Release universal app and a .dmg in dist/
#   make notarize  notarize the newest .dmg (needs a Developer ID + credentials)
#   make test      build and run the unit test bundles
#   make icon      regenerate the app icon PNGs from scripts/AppIconRenderer.swift
#   make selftest  run the in-process acceptance checks against the built app
#   make verify    build, test, then run a headless smoke check of the toolchain
#   make clean     remove build products
#
# This machine's Swift driver cannot start its macro plugin server inside the
# default sandbox, so every target compiles with `-Xfrontend -disable-sandbox`
# (declared in project.yml).  Module caches are also redirected into ./build
# because $TMPDIR is not writable here.

PROJECT       := RideCPP.xcodeproj
SCHEME        := RideCPP
CONFIGURATION := Debug
BUILD_DIR     := $(CURDIR)/build
PRODUCTS      := $(BUILD_DIR)/Build/Products/$(CONFIGURATION)
APP           := $(PRODUCTS)/RideCPP.app

XCODEBUILD_FLAGS := \
	-project $(PROJECT) \
	-scheme $(SCHEME) \
	-configuration $(CONFIGURATION) \
	-derivedDataPath $(BUILD_DIR) \
	CLANG_MODULE_CACHE_PATH=$(BUILD_DIR)/ModuleCache \
	SWIFT_MODULE_CACHE_PATH=$(BUILD_DIR)/ModuleCache \
	CODE_SIGNING_ALLOWED=NO

.PHONY: all generate build run install release dist notarize test selftest icon verify clean open-project help

all: build

help:
	@echo "make generate      regenerate RideCPP.xcodeproj from project.yml (needs xcodegen)"
	@echo "make build         build RideCPP.app into build/Build/Products/Debug"
	@echo "make run           build, then launch the app"
	@echo "make install       install RideCPP.app into /Applications and launch it"
	@echo "make dist          build a Release universal app and package a .dmg"
	@echo "make test          build and run the unit tests"
	@echo "make icon          regenerate the app icon PNGs"
	@echo "make selftest      drive the built app through its acceptance checks"
	@echo "make verify        build + tests + headless compiler smoke test"
	@echo "make clean         remove the build directory"

$(PROJECT):
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found: brew install xcodegen"; exit 1; }
	xcodegen generate

generate:
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found: brew install xcodegen"; exit 1; }
	xcodegen generate

build: $(PROJECT)
	@mkdir -p $(BUILD_DIR)/ModuleCache
	xcodebuild build $(XCODEBUILD_FLAGS) -quiet
	@echo "Built: $(APP)"

run: build
	open "$(APP)"

# Installs into /Applications (the standard location for a Mac app), replacing any
# previous copy so LaunchServices only ever sees one RideCPP.
INSTALL_DIR := /Applications
INSTALLED_APP := $(INSTALL_DIR)/RideCPP.app

# Copying into /Applications replaces the app the user actually runs, so it is
# opt-in. `make install` builds into build/ and stops; only
# `make install RELEASE=1` replaces /Applications/RideCPP.app.
install: build
ifeq ($(filter 1,$(RELEASE) $(RUN_INSTALL_APP)),1)
	@echo "Explicit install requested; replacing $(INSTALLED_APP)."
	@rm -rf "$(INSTALLED_APP)"
	@cp -R "$(APP)" "$(INSTALLED_APP)"
	@# Ad-hoc sign in place so the copied bundle keeps a valid signature.
	@codesign --force --deep --sign - "$(INSTALLED_APP)" >/dev/null 2>&1 || true
	@# Re-register so the Dock, Finder and Spotlight pick up the installed copy.
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-f "$(INSTALLED_APP)" >/dev/null 2>&1 || true
	@# Drop the build-tree copy from LaunchServices so the Dock keeps showing a
	@# single RideCPP (two registrations render as one doubled icon).
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-u "$(CURDIR)/build/Build/Products/$(CONFIGURATION)/RideCPP.app" >/dev/null 2>&1 || true
	@echo "Installed: $(INSTALLED_APP)"
	@open "$(INSTALLED_APP)"
else
	@echo "Refusing to replace $(INSTALLED_APP) automatically."
	@echo "Built app: $(APP)"
	@echo "Run it from there, or: make install RELEASE=1"
endif

# ---------------------------------------------------------------------------
# Distribution
#
# `make dist` produces a Release build for both Apple silicon and Intel and packs
# it into a disk image under dist/. It signs with a "Developer ID Application"
# certificate when one is installed; otherwise it falls back to an ad-hoc
# signature, which runs locally but is blocked by Gatekeeper elsewhere. Run
# `make notarize` afterwards when a Developer ID is available.
# ---------------------------------------------------------------------------

RELEASE_DIR      := $(CURDIR)/build-release
RELEASE_PRODUCTS := $(RELEASE_DIR)/Build/Products/Release
RELEASE_APP      := $(RELEASE_PRODUCTS)/RideCPP.app
DIST_DIR         := $(CURDIR)/dist

release:
	@mkdir -p $(RELEASE_DIR)/ModuleCache
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-derivedDataPath $(RELEASE_DIR) \
		ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
		CLANG_MODULE_CACHE_PATH=$(RELEASE_DIR)/ModuleCache \
		SWIFT_MODULE_CACHE_PATH=$(RELEASE_DIR)/ModuleCache \
		CODE_SIGNING_ALLOWED=NO -quiet
	@./scripts/sign-app.sh "$(RELEASE_APP)"
	@echo "Release build: $(RELEASE_APP)"
	@echo "Architectures: $$(lipo -archs "$(RELEASE_APP)/Contents/MacOS/RideCPP")"

dist: release
	@mkdir -p $(DIST_DIR)
	@DMG=$$(./scripts/make-dmg.sh "$(RELEASE_APP)" "$(DIST_DIR)" | tail -1); \
	echo "Disk image: $$DMG"; \
	echo "Gatekeeper assessment:"; \
	spctl -a -t open --context context:primary-signature -vv "$$DMG" 2>&1 | sed 's/^/  /' || true

notarize:
	@DMG=$$(ls -t $(DIST_DIR)/RideCPP-*.dmg 2>/dev/null | head -1); \
	[ -n "$$DMG" ] || { echo "no .dmg in $(DIST_DIR) — run 'make dist' first"; exit 1; }; \
	./scripts/notarize.sh "$$DMG"

# `xcodebuild test` fails in this environment with "Pseudo Terminal Setup
# Error", so tests are built with build-for-testing and executed directly.
# The icon is drawn in code (scripts/AppIconRenderer.swift) and rendered at exact
# pixel sizes into the asset catalog.
icon:
	@mkdir -p $(BUILD_DIR)/ModuleCache $(BUILD_DIR)/icon
	@mkdir -p $(BUILD_DIR)/icon-src && cp scripts/AppIconRenderer.swift $(BUILD_DIR)/icon-src/
	@printf 'import AppKit\n\nlet app = NSApplication.shared\napp.setActivationPolicy(.accessory)\nlet outDir = CommandLine.arguments[1]\nfor size in [16, 32, 64, 128, 256, 512, 1024] {\n  guard let data = AppIconRenderer.pngData(size: size) else { continue }\n  try? data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("icon_\\(size).png"))\n}\n' > $(BUILD_DIR)/icon-src/main.swift
	@swiftc -module-cache-path $(BUILD_DIR)/ModuleCache -sdk "$$(xcrun --show-sdk-path)" \
		-target arm64-apple-macosx14.0 \
		$(BUILD_DIR)/icon-src/AppIconRenderer.swift $(BUILD_DIR)/icon-src/main.swift \
		-o $(BUILD_DIR)/icon-gen
	@$(BUILD_DIR)/icon-gen Resources/Assets.xcassets/AppIcon.appiconset
	@echo "Icon regenerated at Resources/Assets.xcassets/AppIcon.appiconset"

test: $(PROJECT)
	@mkdir -p $(BUILD_DIR)/ModuleCache
	xcodebuild build-for-testing $(XCODEBUILD_FLAGS) -quiet
	@set -e; \
	for bundle in EditorCoreTests EditorWindowTests BuildKitTests; do \
		echo "=== $$bundle ==="; \
		xcrun xctest "$(PRODUCTS)/$$bundle.xctest"; \
	done

selftest: build
	@mkdir -p $(BUILD_DIR)
	@RIDECPP_SELFTEST="$(BUILD_DIR)/selftest.json" "$(APP)/Contents/MacOS/RideCPP" \
		| grep -E "^\[selftest\]" || { echo "self-test failed"; exit 1; }

verify: build test selftest
	@./scripts/smoke.sh

open-project: $(PROJECT)
	open $(PROJECT)

clean:
	rm -rf "$(BUILD_DIR)"
