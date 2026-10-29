"""Withings direct (HANDOFF.md §9, P6): the scale's weigh-ins straight from Withings' public API, so
the Withings app never has to be opened. No model is called here.

Stateless like the rest of the backend: the phone keeps the tokens in its Keychain and sends them
with each request. The client id and secret come from the env (Fly secrets) only.

- `GET /withings/authorize?state=…` -> `{url}`: Withings' sign-in page for the phone's
  ASWebAuthenticationSession, so the client id never ships in the app.
- `GET /withings/callback` only redirects to `setecho://withings?code=…&state=…`.
- `POST /withings/token` `{code}` or `{refreshToken}` -> `{accessToken, refreshToken, expiresAt}`.
- `POST /withings/weights` `{accessToken, lastUpdate}` -> `[{at, lb}]`.
"""

from __future__ import annotations

import os
from datetime import UTC, datetime, timedelta
from typing import Any
from urllib.parse import urlencode

import httpx
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, RedirectResponse
from pydantic import model_validator

from app.schemas import StrictModel

router = APIRouter()

AUTHORIZE_URL = "https://account.withings.com/oauth2_user/authorize2"
TOKEN_URL = "https://wbsapi.withings.net/v2/oauth2"
MEASURE_URL = "https://wbsapi.withings.net/measure"
APP_CALLBACK = "setecho://withings"
DEFAULT_REDIRECT_URI = "https://setecho-api.fly.dev/withings/callback"
SCOPE = "user.metrics"

LB_PER_KG = 1 / 0.45359237
WEIGHT = 1  # Withings meastype: weight in kg
REAL_MEASURES = 1  # Withings category: real measures, not user objectives
AMBIGUOUS = 1  # attrib: a device reading Withings could not tie to this user (a guest on the scale)
MAX_PAGES = 50
TIMEOUT = httpx.Timeout(20.0, connect=10.0)

# Withings answers HTTP 200 with its own status. These mean the code or token is no good: sign in again.
REFUSED = {100, 101, 102, 200, 401, 503}
TOO_MANY = 601

# Tests replace this with an httpx.MockTransport; nothing in the tests reaches Withings.
transport: httpx.BaseTransport | None = None


class WithingsError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


def _config() -> tuple[str, str]:
    client_id = os.environ.get("WITHINGS_CLIENT_ID", "").strip()
    secret = os.environ.get("WITHINGS_CLIENT_SECRET", "").strip()
    if not client_id or not secret:
        raise WithingsError(
            503, "Withings isn't configured on the server: set WITHINGS_CLIENT_ID and WITHINGS_CLIENT_SECRET"
        )
    return client_id, secret


def redirect_uri() -> str:
    return os.environ.get("WITHINGS_REDIRECT_URI", "").strip() or DEFAULT_REDIRECT_URI


def _post(url: str, data: dict[str, Any], headers: dict[str, str] | None = None) -> dict:
    """One call to Withings. Its status 0 is success; anything else is raised with a readable error."""
    try:
        with httpx.Client(transport=transport, timeout=TIMEOUT) as client:
            r = client.post(url, data=data, headers=headers or {})
    except httpx.HTTPError as e:
        raise WithingsError(502, f"couldn't reach Withings: {e}") from e
    if r.status_code != 200:
        raise WithingsError(502, f"Withings answered HTTP {r.status_code}")
    try:
        payload = r.json()
    except ValueError as e:
        raise WithingsError(502, "Withings answered with something that isn't JSON") from e
    status = payload.get("status")
    if status == 0:
        return payload.get("body") or {}
    detail = payload.get("error") or f"status {status}"
    if status in REFUSED:
        raise WithingsError(401, f"Withings refused the sign-in ({detail}); connect Withings again")
    if status == TOO_MANY:
        raise WithingsError(429, "Withings says too many requests; try again in a few minutes")
    raise WithingsError(502, f"Withings error: {detail}")


# ---------------------------------------------------------------------------
# Pure decoding, tested on the synthetic fixtures
# ---------------------------------------------------------------------------


def kg(value: int, unit: int) -> float:
    """Withings sends value × 10^unit: 82150 with unit -3 is 82.150 kg."""
    return value * 10.0**unit


def kg_to_lb(kilograms: float) -> float:
    return kilograms * LB_PER_KG


def weights(body: dict) -> list[dict]:
    """One `getmeas` page -> [{at, lb}]: weight readings only, never a guest's ambiguous one."""
    out = []
    for group in body.get("measuregrps") or []:
        if group.get("category", REAL_MEASURES) != REAL_MEASURES or group.get("attrib") == AMBIGUOUS:
            continue
        for m in group.get("measures") or []:
            if m.get("type") != WEIGHT:
                continue
            at = datetime.fromtimestamp(int(group["date"]), tz=UTC)
            out.append(
                {"grpid": group.get("grpid"), "at": at, "lb": round(kg_to_lb(kg(m["value"], m["unit"])), 2)}
            )
    return out


def token(body: dict, now: datetime | None = None) -> TokenResponse:
    now = now or datetime.now(UTC)
    try:
        return TokenResponse(
            accessToken=body["access_token"],
            refreshToken=body["refresh_token"],
            expiresAt=now + timedelta(seconds=int(body["expires_in"])),
        )
    except (KeyError, TypeError, ValueError) as e:
        raise WithingsError(502, "Withings' token answer is missing a field") from e


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


class AuthorizeResponse(StrictModel):
    url: str


class TokenRequest(StrictModel):
    """A fresh sign-in's `code`, or the saved `refreshToken`: exactly one."""

    code: str | None = None
    refreshToken: str | None = None

    @model_validator(mode="after")
    def _one(self) -> TokenRequest:
        if bool(self.code) == bool(self.refreshToken):
            raise ValueError("send either code or refreshToken")
        return self


class TokenResponse(StrictModel):
    accessToken: str
    refreshToken: str
    expiresAt: datetime


class WeightsRequest(StrictModel):
    accessToken: str
    lastUpdate: datetime


class Weight(StrictModel):
    at: datetime
    lb: float


def _error(e: WithingsError) -> JSONResponse:
    return JSONResponse(status_code=e.status, content={"error": str(e)})


@router.get("/withings/authorize", response_model=AuthorizeResponse)
def authorize(state: str):
    """The sign-in page's URL. `state` is the phone's random value; it checks it on the way back."""
    try:
        client_id, _ = _config()
    except WithingsError as e:
        return _error(e)
    query = {
        "response_type": "code",
        "client_id": client_id,
        "scope": SCOPE,
        "redirect_uri": redirect_uri(),
        "state": state,
    }
    return AuthorizeResponse(url=f"{AUTHORIZE_URL}?{urlencode(query)}")


@router.get("/withings/callback")
def callback(request: Request) -> RedirectResponse:
    """Withings sends the browser here; this only hands code and state (or error) to the app."""
    passed = {k: v for k, v in request.query_params.items() if k in ("code", "state", "error")}
    return RedirectResponse(f"{APP_CALLBACK}?{urlencode(passed)}", status_code=302)


@router.post("/withings/token", response_model=TokenResponse)
def exchange(req: TokenRequest):
    """Exchange the sign-in code (it expires in 30 s) or refresh. Withings rotates the refresh
    token every time, so the phone saves the one returned here."""
    try:
        client_id, secret = _config()
        data = {"action": "requesttoken", "client_id": client_id, "client_secret": secret}
        if req.code:
            data |= {"grant_type": "authorization_code", "code": req.code, "redirect_uri": redirect_uri()}
        else:
            data |= {"grant_type": "refresh_token", "refresh_token": req.refreshToken}
        return token(_post(TOKEN_URL, data))
    except WithingsError as e:
        return _error(e)


@router.post("/withings/weights", response_model=list[Weight])
def fetch_weights(req: WeightsRequest):
    """Every weigh-in changed since `lastUpdate`, oldest first, following `more`/`offset`."""
    headers = {"Authorization": f"Bearer {req.accessToken}"}
    data: dict[str, Any] = {
        "action": "getmeas",
        "meastypes": WEIGHT,
        "category": REAL_MEASURES,
        "lastupdate": int(req.lastUpdate.timestamp()),
    }
    found: dict[Any, dict] = {}
    try:
        for _ in range(MAX_PAGES):
            body = _post(MEASURE_URL, data, headers)
            for w in weights(body):
                found[w["grpid"] if w["grpid"] is not None else w["at"]] = w
            if not body.get("more"):
                break
            data["offset"] = body.get("offset", 0)
        else:
            raise WithingsError(502, f"Withings kept paging past {MAX_PAGES} pages")
    except WithingsError as e:
        return _error(e)
    return [Weight(at=w["at"], lb=w["lb"]) for w in sorted(found.values(), key=lambda w: w["at"])]
