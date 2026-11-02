"""The spend guard (budget.py): the per-address limit, the daily caps and their midnight reset, the
realtime socket count, and how the API answers over a cap. Never live."""

import json
from datetime import datetime

import pytest
from fastapi.testclient import TestClient

from app import budget, meta, realtime, reps, sets_api, video
from app.main import app

CENTRAL_NOON = datetime(2026, 11, 4, 12, 0, tzinfo=budget.CENTRAL).timestamp()


class Clock:
    def __init__(self, t: float = CENTRAL_NOON):
        self.t = t

    def __call__(self) -> float:
        return self.t


def test_per_ip_limit_counts_a_sliding_minute():
    clock = Clock()
    b = budget.Budget(per_ip_per_minute=3, now=clock)
    for _ in range(3):
        b.check_ip("1.2.3.4")
    with pytest.raises(budget.BudgetExceeded) as e:
        b.check_ip("1.2.3.4")
    assert e.value.body() == {"error": "budget", "detail": e.value.detail}
    b.check_ip("5.6.7.8")  # another address has its own count
    clock.t += 61
    b.check_ip("1.2.3.4")  # the minute has passed


def test_daily_caps_and_the_central_midnight_reset():
    clock = Clock()
    b = budget.Budget(daily_sam_frames=1000, daily_spark_calls=2, now=clock)
    b.charge_sam_frames(600)
    with pytest.raises(budget.BudgetExceeded):
        b.charge_sam_frames(600)
    b.charge_sam_frames(400)  # exactly the cap is still allowed
    b.charge_spark()
    b.charge_spark()
    with pytest.raises(budget.BudgetExceeded):
        b.charge_spark()
    snap = b.snapshot()
    assert snap["samFrames"] == 1000 and snap["sparkCalls"] == 2 and snap["day"] == "2026-11-04"
    # 11:59 PM Central is still today; a minute later everything is clear.
    clock.t = datetime(2026, 11, 4, 23, 59, tzinfo=budget.CENTRAL).timestamp()
    with pytest.raises(budget.BudgetExceeded):
        b.charge_spark()
    clock.t = datetime(2026, 11, 5, 0, 0, 30, tzinfo=budget.CENTRAL).timestamp()
    b.charge_spark()
    b.charge_sam_frames(1000)
    assert b.snapshot()["day"] == "2026-11-05"


def test_realtime_sockets_are_counted_and_released():
    b = budget.Budget(max_realtime_sockets=2)
    assert b.acquire_socket() and b.acquire_socket()
    assert not b.acquire_socket()
    b.release_socket()
    assert b.acquire_socket()
    b.release_socket()
    b.release_socket()
    b.release_socket()  # never below zero
    assert b.snapshot()["realtimeSockets"] == 0


def test_client_ip_prefers_the_proxy_headers():
    assert budget.client_ip({"fly-client-ip": "9.9.9.9"}.get, "127.0.0.1") == "9.9.9.9"
    assert budget.client_ip({"x-forwarded-for": "8.8.8.8, 10.0.0.1"}.get, "127.0.0.1") == "8.8.8.8"
    assert budget.client_ip({}.get, "127.0.0.1") == "127.0.0.1"
    assert budget.client_ip({}.get, None) == "unknown"


def test_env_defaults(monkeypatch):
    monkeypatch.delenv("DAILY_SAM_FRAMES", raising=False)
    monkeypatch.setenv("DAILY_SPARK_CALLS", "12")
    monkeypatch.setenv("MAX_REALTIME_SOCKETS", "nope")
    b = budget.Budget.from_env()
    assert (b.per_ip_per_minute, b.daily_sam_frames, b.daily_spark_calls, b.max_realtime_sockets) == (
        30,
        60_000,
        12,
        4,
    )


@pytest.fixture
def small_budget(monkeypatch):
    """The app's own limiter, replaced for one test: three requests a minute, no model budget at all."""
    b = budget.Budget(per_ip_per_minute=3, daily_sam_frames=0, daily_spark_calls=0, max_realtime_sockets=0)
    monkeypatch.setattr(budget, "budget", b)
    return b


def test_over_the_per_ip_limit_the_api_answers_429(small_budget):
    client = TestClient(app)
    for _ in range(3):
        assert client.get("/import/program").status_code != 429  # 405: the route takes POST, but it counts
    r = client.get("/import/program")
    assert r.status_code == 429
    assert r.json() == {"error": "budget", "detail": "more than 3 requests a minute from one address"}
    # /health is exempt: Fly's checks and the phone's warm-up keep working.
    assert client.get("/health").status_code == 200
    assert client.get("/health").json()["budget"]["perIpPerMinute"] == 3


def test_a_spark_call_over_the_cap_is_a_429_with_no_model_call(small_budget, monkeypatch):
    def never(*args, **kwargs):
        raise AssertionError("Meta was called over budget")

    monkeypatch.setattr(meta, "client", never)
    with pytest.raises(budget.BudgetExceeded):
        meta.spark_json("system", "user", "X", {"type": "object"})
    # Through the API: a phrase the rules don't know goes to Spark, and the guard answers first.
    ctx = {"state": "rest", "exerciseName": "Bench press", "setIndex": 1, "setCount": 3}
    r = TestClient(app).post(
        "/voice/command/text",
        json={"transcript": "what's the weather like in the gym today", "context": ctx},
    )
    assert r.status_code == 429, r.text
    assert r.json()["error"] == "budget"


def test_a_count_over_the_sam_cap_ends_the_stream_with_the_budget_line(small_budget, monkeypatch):
    series = reps.series_from_json(
        json.loads(
            (
                __import__("pathlib").Path(__file__).parent / "fixtures" / "reps" / "clean_8_10fps.json"
            ).read_text()
        )
    )
    monkeypatch.setattr(video, "frame_times", lambda path: [float(v) for v in series.t])
    monkeypatch.setattr(
        meta, "upload_video", lambda path: (_ for _ in ()).throw(AssertionError("uploaded over budget"))
    )
    ctx = {"exerciseId": "w1_upper_a_bench_press", "equipment": "barbell", "plannedReps": 8, "phoneReps": 8}
    r = TestClient(app).post(
        "/sets/count",
        files={"video": ("set.mp4", b"\x00" * 4096, "video/mp4")},
        data={"context": json.dumps(ctx)},
    )
    assert r.status_code == 200  # the stream had started
    last = r.text.strip().splitlines()[-1]
    assert json.loads(last) == {
        "error": "budget",
        "detail": "Setecho's demo budget for SAM is used up for today",
    }
    assert sets_api.MAX_CLIP_BYTES > 0  # the module is the one under test


def test_a_fifth_realtime_socket_is_refused(small_budget, monkeypatch):
    monkeypatch.setenv("MODEL_API_KEY", "k")
    client = TestClient(app)
    with client.websocket_connect("/voice/stream") as ws:
        first = ws.receive_json()
    assert first["type"] == "error" and first["message"].startswith("budget")
    assert realtime.REALTIME_URL.startswith("wss://")
