.PHONY: dev test lint smoke ios ios-test screens testflight watch watch-sim

SIM ?= iPhone 17 Pro
DD := /tmp/setecho-derived-data
ARCHIVE_DIR := /tmp/setecho-archive
BUILD_NUMBER ?= $(shell date +%Y%m%d%H%M)

dev:        ## backend on your LAN so the phone can reach it
	cd backend && uv run uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

test:       ## offline tests only; never hits Meta
	cd backend && uv run pytest -q

lint:
	cd backend && uv run ruff check . && uv run ruff format --check .

smoke:      ## one cheap live call: key, base URL, model ids
	cd backend && uv run python -m scripts.smoke

ios:        ## regenerate and open the Xcode project
	cd ios && xcodegen generate && open Setecho.xcodeproj

ios-test:   ## iOS unit tests on the simulator
	cd ios && xcodegen generate && xcodebuild -project Setecho.xcodeproj -scheme Setecho \
		-destination 'platform=iOS Simulator,name=$(SIM)' -derivedDataPath $(DD) -quiet test

SHOTS_SIM ?= Setecho Shots
SCREENS := $(CURDIR)/design/screens
# A sample frame for the session's camera card (design/, gitignored); the placeholder without one.
HUD_CAMERA ?= $(wildcard $(CURDIR)/design/hud-camera.jpg)

screens:    ## render every screen to design/screens (gitignored) and build the contact sheets
	rm -rf $(SCREENS) && mkdir -p $(SCREENS)
	cd ios && xcodegen generate && TEST_RUNNER_SCREEN_SHOTS=$(SCREENS) TEST_RUNNER_HUD_CAMERA=$(HUD_CAMERA) \
		xcodebuild -project Setecho.xcodeproj -scheme Setecho -destination 'platform=iOS Simulator,name=$(SHOTS_SIM)' \
		-derivedDataPath /tmp/setecho-shots-dd -quiet test -only-testing:SetechoTests/ScreenRenderTests
	uv run --no-project --with pillow python ios/scripts/contact_sheet.py $(SCREENS)

testflight: ## archive a Release build and upload it to TestFlight (Xcode signed in; app record in App Store Connect)
	cd ios && xcodegen generate
	rm -rf $(ARCHIVE_DIR) && mkdir -p $(ARCHIVE_DIR)
	cd ios && xcodebuild -project Setecho.xcodeproj -scheme Setecho -configuration Release \
		-destination 'generic/platform=iOS' -archivePath $(ARCHIVE_DIR)/Setecho.xcarchive \
		-allowProvisioningUpdates CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) -quiet archive
	TEAM=$$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' ios/Config/Local.xcconfig | tr -d '[:space:]'); \
		test -n "$$TEAM" || { echo "Set DEVELOPMENT_TEAM in ios/Config/Local.xcconfig"; exit 1; }; \
		sed "s/TEAM_ID/$$TEAM/" ios/Config/ExportOptions.plist > $(ARCHIVE_DIR)/ExportOptions.plist
	cd ios && xcodebuild -exportArchive -archivePath $(ARCHIVE_DIR)/Setecho.xcarchive \
		-exportOptionsPlist $(ARCHIVE_DIR)/ExportOptions.plist -exportPath $(ARCHIVE_DIR)/export \
		-allowProvisioningUpdates
	@echo "Uploaded build $(BUILD_NUMBER). It shows in TestFlight after Apple processes it (a few minutes)."

# --- Garmin watch app (watch/README.md). Needs the Connect IQ SDK Manager and ~/.garmin/developer_key.der.
CIQ_SDK := $(shell cat "$(HOME)/Library/Application Support/Garmin/ConnectIQ/current-sdk.cfg" 2>/dev/null)
CIQ_DEVICE ?= venu4
WATCH_KEY ?= $(HOME)/.garmin/developer_key.der

watch:      ## build watch/bin/SetechoWatch.prg
	@test -n "$(CIQ_SDK)" || { echo "Install the Connect IQ SDK with the SDK Manager first (watch/README.md)"; exit 1; }
	@test -f "$(WATCH_KEY)" || { echo "No developer key at $(WATCH_KEY) (watch/README.md)"; exit 1; }
	@ls "$(HOME)/Library/Application Support/Garmin/ConnectIQ/Devices" | grep -i venu4 || echo "No Venu 4 device files installed yet; check the ids in watch/manifest.xml"
	cd watch && "$(CIQ_SDK)/bin/monkeyc" -f monkey.jungle -o bin/SetechoWatch.prg -d $(CIQ_DEVICE) -y "$(WATCH_KEY)" -w -l 1

watch-sim:  ## run it in the Connect IQ simulator
	"$(CIQ_SDK)/bin/connectiq" & sleep 4
	"$(CIQ_SDK)/bin/monkeydo" watch/bin/SetechoWatch.prg $(CIQ_DEVICE)
