"""The /import endpoints, driven offline by the Spark output saved from the probes."""

import json
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from app import importing, meta
from app.main import app

FIXTURES = Path(__file__).parent / "fixtures"
PROGRAM_RAW = json.loads((FIXTURES / "spark" / "program_synthetic_program.json").read_text())["raw"]
FORM_RAW = json.loads((FIXTURES / "spark" / "form_synthetic_form.json").read_text())["raw"]
SHEET_CSV = FIXTURES / "import" / "synthetic_program.csv"
FORM_TXT = FIXTURES / "import" / "synthetic_form.txt"


@pytest.fixture
def client():
    return TestClient(app)


@pytest.fixture
def spark(monkeypatch):
    """Replace the live call: return the fixture that matches the schema name, record what was sent."""
    calls: list[dict] = []

    def fake(system, user, schema_name, schema):
        calls.append({"system": system, "user": user, "schema": schema_name})
        return ({"Program": PROGRAM_RAW, "CheckInTemplate": FORM_RAW}[schema_name], None)

    monkeypatch.setattr(meta, "spark_json", fake)
    return calls


def test_health_lists_models(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["models"] == {
        "spark": "muse-spark-1.3",
        "transcribe": "muse-voice-transcribe-1.0",
        "sam": "sam-3.1",
    }


def test_import_program_from_csv_file(client, spark):
    with SHEET_CSV.open("rb") as f:
        r = client.post("/import/program", files={"file": ("program.csv", f, "text/csv")})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["name"].startswith("Prep Block 2")
    assert body["weeks"][0]["days"][0]["id"] == "w1_upper_a"
    assert body["weeks"][0]["days"][0]["exercises"][0]["sets"][0] == {
        "reps": 8, "repsMin": None, "repsMax": None, "loadLb": 185.0, "rpe": 8.0, "rir": None
    }  # fmt: skip
    assert len(body["flags"]) == 4 and "importedAt" in body
    assert spark[0]["schema"] == "Program"
    assert "Bench press,4,8,185,8,2:30" in spark[0]["user"]  # the CSV text reached the prompt


def test_import_program_from_pasted_text(client, spark):
    r = client.post("/import/program", data={"text": SHEET_CSV.read_text()})
    assert r.status_code == 200
    assert spark[0]["user"].startswith("Convert this training spreadsheet.")


def test_import_program_from_sheets_link(client, spark, monkeypatch):
    seen: list[str] = []

    def fake_fetch(link, timeout=30.0):
        seen.append(link)
        return importing.Upload("sheet.csv", SHEET_CSV.read_bytes())

    monkeypatch.setattr(importing, "fetch_sheet", fake_fetch)
    link = "https://docs.google.com/spreadsheets/d/1AbC_dEf-123/edit#gid=0"
    r = client.post("/import/program", data={"url": link})
    assert r.status_code == 200
    assert seen == [link]


def test_import_program_image_goes_as_data_url(client, spark):
    png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 16
    r = client.post("/import/program", files={"file": ("sheet.png", png, "image/png")})
    assert r.status_code == 200
    content = spark[0]["user"]
    assert isinstance(content, list) and content[1]["image_url"]["url"].startswith("data:image/png;base64,")


def test_import_program_with_nothing_is_422(client, spark):
    r = client.post("/import/program", data={"text": "   "})
    assert r.status_code == 422
    assert "nothing to import" in r.json()["error"]
    assert spark == []


def test_import_program_unsupported_file_is_422(client, spark):
    r = client.post("/import/program", files={"file": ("program.pdf", b"%PDF-1.4", "application/pdf")})
    assert r.status_code == 422
    assert "unsupported file type" in r.json()["error"]


def test_import_program_invalid_model_output_is_422(client, monkeypatch):
    monkeypatch.setattr(meta, "spark_json", lambda *a, **k: ({"name": "x", "weeks": "nope"}, None))
    r = client.post("/import/program", data={"text": "Week 1, Bench"})
    assert r.status_code == 422
    assert "failed validation" in r.json()["error"]


def test_import_form_from_json_text(client, spark):
    r = client.post("/import/form", json={"text": FORM_TXT.read_text()})
    assert r.status_code == 200, r.text
    body = r.json()
    assert len(body["fields"]) == 23
    assert body["fields"][0] == {
        "label": "Weeks away from target date", "prompt": None, "kind": "number",
        "source": {"type": "calculated", "key": "weeksToShow"}, "id": "weeks_away_from_target_date", "order": 0,
    }  # fmt: skip
    assert [b["title"] for b in body["carriedBlocks"]] == [
        "Macro targets (until I change them):",
        "Supplements:",
    ]
    assert spark[0]["schema"] == "CheckInTemplate"


def test_import_form_from_screenshot(client, spark):
    r = client.post("/import/form", files={"file": ("form.jpg", b"\xff\xd8\xff" + b"\x00" * 8, "image/jpeg")})
    assert r.status_code == 200
    assert spark[0]["user"][1]["image_url"]["url"].startswith("data:image/jpeg;base64,")


def test_import_form_empty_json_is_422(client, spark):
    r = client.post("/import/form", json={"text": ""})
    assert r.status_code == 422


def test_sheets_export_url():
    assert (
        importing.sheets_export_url("https://docs.google.com/spreadsheets/d/1AbC_dEf-123/edit?usp=sharing")
        == "https://docs.google.com/spreadsheets/d/1AbC_dEf-123/export?format=xlsx"
    )
    with pytest.raises(importing.ImportError_, match="not a Google Sheets link"):
        importing.sheets_export_url("https://example.com/sheet.xlsx")


def test_fetch_sheet_rejects_a_private_sheet(monkeypatch):
    resp = SimpleNamespace(
        status_code=200, headers={"content-type": "text/html; charset=utf-8"}, content=b"<html>Sign in</html>"
    )
    monkeypatch.setattr(importing.httpx, "get", lambda *a, **k: resp)
    with pytest.raises(importing.ImportError_, match="not shared"):
        importing.fetch_sheet("https://docs.google.com/spreadsheets/d/abc/edit")
