PROJECT     := Tracker.xcodeproj
SCHEME      := Tracker
TARGET      := Tracker
BUNDLE_ID   := net.acheris.tracker
CONFIG      ?= Release

DERIVED     := $(CURDIR)/build
XCODEBUILD  := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -derivedDataPath $(DERIVED)

.PHONY: build debug run kill rerun clean load history-30 history-180 show-defaults app-path icon

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
