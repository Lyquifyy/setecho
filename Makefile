.PHONY: dev test lint smoke ios ios-test testflight

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
