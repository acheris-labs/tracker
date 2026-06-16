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

.PHONY: build debug run kill rerun clean load history-30 history-180 show-defaults app-path icon sign notarize dmg setup-notary setup-secrets

# --- Credential bootstrap ---------------------------------------------------
# Reusable shell snippet that reads the Developer ID identity + Team ID from
# your keychain. Inlined into the recipes so this only runs when invoked.
define _devid_detect
DEVID_LINE=$$(security find-identity -v -p codesigning \
  | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+[A-F0-9]+[[:space:]]+"(.*)".*$$/\1/p' \
  | head -1); \
test -n "$$DEVID_LINE" || { echo "no Developer ID Application identity in keychain"; exit 1; }; \
DEVID_TEAM=$$(echo "$$DEVID_LINE" | sed -nE 's/.*\(([A-Z0-9]+)\).*/\1/p')
endef

# Store the notarytool keychain profile. Run once per machine.
#   1. Copy the 19-char app-specific password from appleid.apple.com to your clipboard.
#   2. make setup-notary APPLE_ID=you@example.com
setup-notary:
	@test -n "$(APPLE_ID)" || { \
	  echo "usage: make setup-notary APPLE_ID=you@example.com"; \
	  echo "(copy your 19-char app-specific password to the clipboard first)"; \
	  exit 1; }
	@bash -ec '$(_devid_detect); \
	  PW=$$(pbpaste); \
	  test $${#PW} -eq 19 || { echo "clipboard is $${#PW} chars, expected 19 (xxxx-xxxx-xxxx-xxxx)"; exit 1; }; \
	  xcrun notarytool store-credentials $(NOTARY_PROFILE) \
	    --apple-id "$(APPLE_ID)" --team-id "$$DEVID_TEAM" --password "$$PW"; \
	  echo "notarytool profile $(NOTARY_PROFILE) is ready (team $$DEVID_TEAM)"'

# Upload Developer ID + notary credentials to GitHub as org-level secrets
# scoped to the listed repos. Run once after exporting the cert as .p12.
#   1. Keychain Access → My Certificates → right-click Developer ID Application
#      → Export → save as devid.p12 with a strong password.
#   2. Copy your app-specific password to the clipboard.
#   3. make setup-secrets P12=path/to/devid.p12 APPLE_ID=you@example.com \
#                         ORG=acheris-labs REPOS=tracker,newt
setup-secrets:
	@test -f "$(P12)" || { echo "set P12=path/to/devid.p12"; exit 1; }
	@test -n "$(APPLE_ID)" || { echo "set APPLE_ID=you@example.com"; exit 1; }
	@test -n "$(ORG)"      || { echo "set ORG=acheris-labs"; exit 1; }
	@test -n "$(REPOS)"    || { echo "set REPOS=tracker,newt"; exit 1; }
	@bash -ec '$(_devid_detect); \
	  read -s -p ".p12 export password: " P12_PW; echo; \
	  APP_PW=$$(pbpaste); \
	  test $${#APP_PW} -eq 19 || { echo "clipboard not a 19-char app-specific password"; exit 1; }; \
	  echo "uploading to $(ORG) repos: $(REPOS)"; \
	  base64 -i "$(P12)"        | gh secret set DEVID_CERT_P12      --org $(ORG) --repos $(REPOS); \
	  printf "%s" "$$P12_PW"    | gh secret set DEVID_CERT_PASSWORD --org $(ORG) --repos $(REPOS); \
	  printf "%s" "$$DEVID_LINE"| gh secret set DEVID_IDENTITY      --org $(ORG) --repos $(REPOS); \
	  printf "%s" "$(APPLE_ID)" | gh secret set APPLE_ID            --org $(ORG) --repos $(REPOS); \
	  printf "%s" "$$DEVID_TEAM"| gh secret set APPLE_TEAM_ID       --org $(ORG) --repos $(REPOS); \
	  printf "%s" "$$APP_PW"    | gh secret set APPLE_APP_PASSWORD  --org $(ORG) --repos $(REPOS); \
	  echo done'

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

# Notarized .dmg ready to ship. The app inside is already notarized + stapled by
# the `notarize` dependency; we then sign, notarize, and staple the DMG itself so
# a directly-downloaded container clears Gatekeeper on mount without a prompt.
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
	codesign --force --sign "$(SIGN_ID)" --timestamp build/$(TARGET).dmg; \
	xcrun notarytool submit build/$(TARGET).dmg \
	  --keychain-profile $(NOTARY_PROFILE) --wait; \
	xcrun stapler staple build/$(TARGET).dmg; \
	xcrun stapler validate build/$(TARGET).dmg; \
	echo "signed + notarized + stapled build/$(TARGET).dmg"
