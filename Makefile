# Assembles the Shepherd .app bundle from SwiftPM build products.
# No Xcode project: swift build + a hand-rolled bundle is all there is.
# Local development uses ad-hoc signing and the current arch only; releases
# (CI) pass ARCHS / SIGN_IDENTITY / VERSION for a universal + Developer ID
# build (.github/workflows/release.yml is the caller).

APP := dist/Shepherd.app
ZIP := dist/Shepherd.zip

# Signing identity. The default "-" is ad-hoc. Releases pass
# SIGN_IDENTITY="Developer ID Application" (resolved by partial match).
# Hardened runtime + secure timestamp are added only for Developer ID:
# both are required for notarization (notarytool), while --timestamp on an
# ad-hoc signature makes codesign fail because there is no key a timestamp
# server request can be signed with.
SIGN_IDENTITY := -
ifeq ($(SIGN_IDENTITY),-)
CODESIGN_FLAGS :=
else
CODESIGN_FLAGS := --options runtime --timestamp
endif

# Target architectures. Empty (default) builds the current arch only.
# Releases pass ARCHS="arm64 x86_64" for a universal binary.
# Passing any --arch makes SwiftPM place products under
# .build/apple/Products/Release instead of .build/release, so BUILD_DIR
# switches along with it.
ARCHS :=
ifeq ($(ARCHS),)
BUILD_DIR := .build/release
ARCH_FLAGS :=
else
BUILD_DIR := .build/apple/Products/Release
ARCH_FLAGS := $(foreach arch,$(ARCHS),--arch $(arch))
endif

BINARY := $(BUILD_DIR)/Shepherd
# Sparkle.framework from the SwiftPM binary artifact. The xcframework ships a
# single universal (arm64 + x86_64) macOS slice, so the same path serves both
# local single-arch and release universal builds. SwiftPM also copies the
# framework next to BINARY, which the @loader_path rpath resolves for bare
# build-dir runs (make screenshots); inside the .app the executable finds the
# embedded copy through the @executable_path/../Frameworks rpath added below.
SPARKLE_FRAMEWORK := .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
# Bundle SPM generates from the resources declaration. At runtime
# Bundle.module looks for it under Bundle.main.resourceURL
# (= Contents/Resources), so unless it ships inside the .app, resource
# lookups (AgentIcons) die with a fatalError.
RESOURCE_BUNDLE := $(BUILD_DIR)/Shepherd_Shepherd.bundle

# Release version. When set, rewrites CFBundleShortVersionString /
# CFBundleVersion in the Info.plist copied into the .app (the tree's
# Support/Info.plist is left untouched). CI passes "1.2.3" from tag v1.2.3.
VERSION :=
# App icon. The generated .icns lives in the tree and the app build only
# copies it (the design rarely changes, so it is not re-rendered on every
# build). To change the design, edit Support/GenerateAppIcon.swift and run
# make icon. The PNG is for the README and regenerates from the same source
# alongside the icns. Support/StatusIcons/ holds the menu bar status icons
# written out by GenerateStatusIcons.swift for the README legend; make icon
# regenerates them as well.
ICNS := Support/AppIcon.icns
ICON_PNG := Support/AppIcon.png
ICONSET := .build/AppIcon.iconset
STATUS_ICONS := Support/StatusIcons
# README screenshots. The app's own --render-screenshots mode
# (ScreenshotRenderer) renders the MenuPanel with mock data, headless.
SCREENSHOTS := Support/Screenshots

.PHONY: app zip build icon screenshots run clean

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Frameworks
	cp $(BINARY) $(APP)/Contents/MacOS/Shepherd
	cp -R $(RESOURCE_BUNDLE) $(APP)/Contents/Resources/
	cp $(ICNS) $(APP)/Contents/Resources/AppIcon.icns
	cp Support/Info.plist $(APP)/Contents/Info.plist
ifneq ($(VERSION),)
	/usr/libexec/PlistBuddy \
		-c "Set :CFBundleShortVersionString $(VERSION)" \
		-c "Set :CFBundleVersion $(VERSION)" \
		$(APP)/Contents/Info.plist
endif
	ditto $(SPARKLE_FRAMEWORK) $(APP)/Contents/Frameworks/Sparkle.framework
	install_name_tool -add_rpath @executable_path/../Frameworks \
		$(APP)/Contents/MacOS/Shepherd
# Nested code first, then the framework, then the app: codesign does not
# re-sign nested items, and notarization rejects a bundle whose inner
# binaries lack the hardened runtime. Downloader.xpc keeps its sandbox
# entitlement via --preserve-metadata.
	codesign --force --sign "$(SIGN_IDENTITY)" $(CODESIGN_FLAGS) \
		--preserve-metadata=entitlements \
		$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
	codesign --force --sign "$(SIGN_IDENTITY)" $(CODESIGN_FLAGS) \
		$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc
	codesign --force --sign "$(SIGN_IDENTITY)" $(CODESIGN_FLAGS) \
		$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
	codesign --force --sign "$(SIGN_IDENTITY)" $(CODESIGN_FLAGS) \
		$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
	codesign --force --sign "$(SIGN_IDENTITY)" $(CODESIGN_FLAGS) \
		$(APP)/Contents/Frameworks/Sparkle.framework
	codesign --force --sign "$(SIGN_IDENTITY)" $(CODESIGN_FLAGS) $(APP)

# Distribution zip. Plain zip can drop resource forks and signing
# metadata and break Gatekeeper verification, so build it with ditto -c -k.
zip: app
	ditto -c -k --keepParent $(APP) $(ZIP)

icon:
	rm -rf $(ICONSET)
	swift Support/GenerateAppIcon.swift $(ICONSET)
	iconutil -c icns $(ICONSET) -o $(ICNS)
	cp $(ICONSET)/icon_256x256.png $(ICON_PNG)
	rm -rf $(ICONSET)
	swift Support/GenerateStatusIcons.swift $(STATUS_ICONS)

screenshots: build
	$(BINARY) --render-screenshots $(SCREENSHOTS)

build:
	swift build -c release $(ARCH_FLAGS)

run: app
	open $(APP)

clean:
	rm -rf .build dist
