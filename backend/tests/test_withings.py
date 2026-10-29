"""Withings direct, offline: Withings is replaced by an httpx.MockTransport that answers with the
hand-written fixtures in fixtures/withings/. Nothing here reaches Withings."""

import json
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from fastapi.testclient import TestClient

from app import withings
from app.main import app

FIXTURES = Path(__file__).parent / "fixtures" / "withings"


def fixture(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text())


@pytest.fixture
def configured(monkeypatch):
    monkeypatch.setenv("WITHINGS_CLIENT_ID", "synthetic-client")
    monkeypatch.setenv("WITHINGS_CLIENT_SECRET", "synthetic-secret")


@pytest.fixture
def withings_api(monkeypatch):
    """Answers each call from a queue of fixtures and records the form it was sent."""
    sent: list[dict] = []
    answers: list[dict] = []

    def handle(request: httpx.Request) -> httpx.Response:
        form = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
        sent.append({"url": str(request.url), "form": form, "auth": request.headers.get("authorization")})
        return httpx.Response(200, json=answers.pop(0))

    monkeypatch.setattr(withings, "transport", httpx.MockTransport(handle))
    return sent, answers


client = TestClient(app)


# --- decoding ---------------------------------------------------------------


def test_value_and_unit_decode_to_kilograms():
    assert withings.kg(82150, -3) == pytest.approx(82.15)
    assert withings.kg(8190, -2) == pytest.approx(81.9)
    assert withings.kg(818, -1) == pytest.approx(81.8)
    assert withings.kg(82, 0) == 82


def test_kilograms_convert_to_pounds():
    assert withings.kg_to_lb(1) == pytest.approx(2.20462262)
    assert withings.kg_to_lb(82.15) == pytest.approx(181.1097, abs=1e-4)
    assert withings.kg_to_lb(45.359237) == pytest.approx(100)


def test_a_page_keeps_only_this_users_real_weigh_ins():
    page = withings.weights(fixture("measure_page1.json")["body"])
    # 9002 is ambiguous (attrib 1: a guest on the scale), so only 9001 is his.
    assert [(w["grpid"], w["lb"]) for w in page] == [(9001, 181.11)]
    assert page[0]["at"] == datetime.fromtimestamp(1793000000, tz=UTC)
    # Category 2 is a goal, not a reading.
    assert [w["grpid"] for w in withings.weights(fixture("measure_page2.json")["body"])] == [9003, 9004]


# --- /withings/weights --------------------------------------------------------


def test_weights_follow_more_and_offset_until_more_is_zero(withings_api):
    sent, answers = withings_api
    answers += [fixture("measure_page1.json"), fixture("measure_page2.json")]
    r = client.post("/withings/weights", json={"accessToken": "tok", "lastUpdate": "2026-10-20T09:00:00Z"})
    assert r.status_code == 200
    assert r.json() == [
        {"at": "2026-10-26T07:33:20Z", "lb": 181.11},
        {"at": "2026-10-27T07:33:20Z", "lb": 180.56},
        {"at": "2026-10-28T07:33:20Z", "lb": 180.34},
    ]
    assert len(sent) == 2
    first, second = sent[0]["form"], sent[1]["form"]
    assert sent[0]["url"] == withings.MEASURE_URL
    assert sent[0]["auth"] == "Bearer tok"
    assert first == {"action": "getmeas", "meastypes": "1", "category": "1", "lastupdate": "1792486800"}
    assert "offset" not in first
    assert second["offset"] == "2"


def test_weights_need_no_client_secret(withings_api, monkeypatch):
    monkeypatch.delenv("WITHINGS_CLIENT_ID", raising=False)
    _, answers = withings_api
    answers.append(fixture("measure_page2.json"))
    r = client.post("/withings/weights", json={"accessToken": "tok", "lastUpdate": "2026-10-20T09:00:00Z"})
    assert r.status_code == 200


def test_a_refused_access_token_is_401(withings_api):
    _, answers = withings_api
    answers.append(fixture("invalid_token.json"))
    r = client.post("/withings/weights", json={"accessToken": "old", "lastUpdate": "2026-10-20T09:00:00Z"})
    assert r.status_code == 401
    assert "connect Withings again" in r.json()["error"]


def test_too_many_requests_is_429_not_a_sign_out(withings_api):
    _, answers = withings_api
    answers.append({"status": 601, "body": {}, "error": "Too Many Requests"})
    r = client.post("/withings/weights", json={"accessToken": "tok", "lastUpdate": "2026-10-20T09:00:00Z"})
    assert r.status_code == 429


def test_endless_paging_stops(withings_api):
    _, answers = withings_api
    answers += [fixture("measure_page1.json")] * withings.MAX_PAGES
    r = client.post("/withings/weights", json={"accessToken": "tok", "lastUpdate": "2026-10-20T09:00:00Z"})
    assert r.status_code == 502


# --- /withings/token ------------------------------------------------------------


def test_code_exchange_returns_both_tokens_and_expiry(configured, withings_api):
    sent, answers = withings_api
    answers.append(fixture("token.json"))
    before = datetime.now(UTC)
    r = client.post("/withings/token", json={"code": "code-1"})
    assert r.status_code == 200
    body = r.json()
    assert body["accessToken"] == "synthetic-access-1"
    assert body["refreshToken"] == "synthetic-refresh-1"
    expires = datetime.fromisoformat(body["expiresAt"])
    assert 10790 <= (expires - before).total_seconds() <= 10810
    form = sent[0]["form"]
    assert sent[0]["url"] == withings.TOKEN_URL
    assert form["action"] == "requesttoken"
    assert form["grant_type"] == "authorization_code"
    assert form["code"] == "code-1"
    assert form["client_id"] == "synthetic-client" and form["client_secret"] == "synthetic-secret"
    assert form["redirect_uri"] == withings.DEFAULT_REDIRECT_URI


def test_refresh_returns_the_rotated_refresh_token(configured, withings_api):
    sent, answers = withings_api
    answers.append(fixture("token_refreshed.json"))
    r = client.post("/withings/token", json={"refreshToken": "synthetic-refresh-1"})
    assert r.status_code == 200
    assert r.json()["refreshToken"] == "synthetic-refresh-2"  # the new one: the old stops working
    form = sent[0]["form"]
    assert form["grant_type"] == "refresh_token"
    assert form["refresh_token"] == "synthetic-refresh-1"
    assert "code" not in form


def test_a_refused_refresh_is_401(configured, withings_api):
    _, answers = withings_api
    answers.append(fixture("refused.json"))
    r = client.post("/withings/token", json={"refreshToken": "revoked"})
    assert r.status_code == 401


def test_token_needs_exactly_one_of_code_or_refresh(configured):
    assert client.post("/withings/token", json={}).status_code == 422
    assert client.post("/withings/token", json={"code": "a", "refreshToken": "b"}).status_code == 422


def test_missing_secrets_say_not_configured(monkeypatch, withings_api):
    monkeypatch.delenv("WITHINGS_CLIENT_ID", raising=False)
    monkeypatch.delenv("WITHINGS_CLIENT_SECRET", raising=False)
    sent, _ = withings_api
    for r in (client.post("/withings/token", json={"code": "a"}), client.get("/withings/authorize?state=s")):
        assert r.status_code == 503
        assert "isn't configured" in r.json()["error"]
        assert "WITHINGS_CLIENT_SECRET" in r.json()["error"]
    assert sent == []


# --- sign-in --------------------------------------------------------------------


def test_authorize_builds_the_sign_in_url(configured):
    r = client.get("/withings/authorize", params={"state": "abc123"})
    assert r.status_code == 200
    url = urlparse(r.json()["url"])
    assert f"{url.scheme}://{url.netloc}{url.path}" == withings.AUTHORIZE_URL
    q = {k: v[0] for k, v in parse_qs(url.query).items()}
    assert q == {
        "response_type": "code",
        "client_id": "synthetic-client",
        "scope": "user.metrics",
        "redirect_uri": "https://setecho-api.fly.dev/withings/callback",
        "state": "abc123",
    }
    assert "synthetic-secret" not in r.text


def test_callback_only_redirects_to_the_app():
    r = client.get(
        "/withings/callback", params={"code": "c 1", "state": "s1", "other": "x"}, follow_redirects=False
    )
    assert r.status_code == 302
    assert r.headers["location"] == "setecho://withings?code=c+1&state=s1"


def test_callback_passes_a_denial_through():
    r = client.get(
        "/withings/callback", params={"error": "access_denied", "state": "s1"}, follow_redirects=False
    )
    assert r.headers["location"] == "setecho://withings?error=access_denied&state=s1"
