.PHONY: dev test lint smoke ios

dev:        ## backend on your LAN so the phone can reach it
	cd backend && uv run uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

test:       ## offline tests only; never hits Meta
	cd backend && uv run pytest -q

lint:
	cd backend && uv run ruff check . && uv run ruff format --check .

smoke:      ## one cheap live call: key, base URL, model ids
	cd backend && uv run python -m scripts.smoke

ios:        ## regenerate and open the Xcode project
	cd ios && xcodegen generate && open Chalkline.xcodeproj
