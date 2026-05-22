PROJECT     := Tracker.xcodeproj
SCHEME      := Tracker
TARGET      := Tracker
BUNDLE_ID   := net.acheris.tracker
CONFIG      ?= Release

DERIVED     := $(CURDIR)/build
XCODEBUILD  := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -derivedDataPath $(DERIVED)

# --- Code signing -----------------------------------------------------------
# SIGN_ID defaults to ad-hoc ("-"). For a distributable, notarizable build pass
# a Developer ID (see DISTRIBUTING.md):
#   make dmg SIGN_ID="Developer ID Application: Chris Madden (TEAMID)"
SIGN_ID        ?= -
NOTARY_PROFILE ?= tracker-notary

# Hardened runtime + secure timestamp are required for notarization, but are
# rejected by ad-hoc signing — only add them with a real identity.
ifeq ($(SIGN_ID),-)
  HARDENED :=
else
  HARDENED := --options runtime --timestamp
endif

.PHONY: build debug run kill rerun clean load history-30 history-180 show-defaults app-path icon sign notarize dmg

build:
	$(XCODEBUILD) build

debug:
	$(MAKE) build CONFIG=Debug

app-path:
	@$(XCODEBUILD) -showBuildSettings 2>/dev/null \
	  | awk -F' = ' '/^[ \t]*BUILT_PRODUCTS_DIR/ { print $$2 "/$(TARGET).app"; exit }'

run: build
	@APP=$$($(MAKE) -s app-path); \
	echo "opening $$APP"; \
	open "$$APP"

kill:
	-killall $(TARGET) 2>/dev/null || true
	@sleep 0.3
	-pgrep -x $(TARGET) >/dev/null && killall -9 $(TARGET) 2>/dev/null || true

rerun: kill run

clean:
	$(XCODEBUILD) clean
	rm -rf build

load:
	@echo "spawning 4x 'yes > /dev/null' for 30s"
	@yes > /dev/null & yes > /dev/null & yes > /dev/null & yes > /dev/null & \
	  PIDS="$$!"; sleep 30; killall yes 2>/dev/null; echo done

history-30:
	defaults write $(BUNDLE_ID) HistorySeconds -int 30

history-180:
	defaults write $(BUNDLE_ID) HistorySeconds -int 180

badge-threshold-%:
	defaults write $(BUNDLE_ID) BadgeThresholdWatts -int $*

show-defaults:
	-defaults read $(BUNDLE_ID) 2>/dev/null || echo "(no defaults set)"

icon:
	swift tools/gen-icon.swift Tracker.iconset
	iconutil -c icns Tracker.iconset -o Tracker/Tracker.icns
	rm -rf Tracker.iconset
	@echo "wrote Tracker/Tracker.icns"

# --- Distribution -----------------------------------------------------------
# Re-sign the built .app with the configured identity. Tracker is a single
# executable bundle with no nested code, so one codesign on the bundle suffices.
sign: build
	@APP=$$($(MAKE) -s app-path); \
	codesign --force --sign "$(SIGN_ID)" $(HARDENED) "$$APP"; \
	codesign --verify --verbose "$$APP"; \
	echo "signed $$APP  ($(SIGN_ID))"

# Notarize the signed app. Requires SIGN_ID set to a Developer ID and a
# notarytool keychain profile created once with:
#   xcrun notarytool store-credentials $(NOTARY_PROFILE) \
#     --apple-id <id> --team-id <TEAMID> --password <app-specific-password>
notarize: sign
	@test "$(SIGN_ID)" != "-" || { \
	  echo "error: set SIGN_ID to a Developer ID — see DISTRIBUTING.md"; exit 1; }
	@APP=$$($(MAKE) -s app-path); \
	rm -f build/$(TARGET).zip; \
	ditto -c -k --keepParent "$$APP" build/$(TARGET).zip; \
	xcrun notarytool submit build/$(TARGET).zip \
	  --keychain-profile $(NOTARY_PROFILE) --wait; \
	xcrun stapler staple "$$APP"; \
	xcrun stapler validate "$$APP"; \
	echo "notarized + stapled $$APP"

# Notarized .dmg ready to ship.
dmg: notarize
	@command -v create-dmg >/dev/null || brew install create-dmg
	@APP=$$($(MAKE) -s app-path); \
	rm -rf build/staging && mkdir -p build/staging; \
	cp -R "$$APP" build/staging/; \
	rm -f build/$(TARGET).dmg; \
	create-dmg \
	  --volname "$(TARGET)" \
	  --window-size 540 360 --icon-size 96 \
	  --icon "$(TARGET).app" 140 180 \
	  --hide-extension "$(TARGET).app" \
	  --app-drop-link 400 180 \
	  build/$(TARGET).dmg build/staging/; \
	echo "built build/$(TARGET).dmg"
