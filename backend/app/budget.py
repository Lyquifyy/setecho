"""The spend guard (design handoff, Nov 1 §5): the API has no sign-in, its URL is in the public
README, and every call spends Meta credits. In-memory counters are enough: Fly runs one machine
(`min_machines_running = 1`), and they reset at midnight Central and on restart.

- Per IP: `PER_IP_PER_MINUTE` requests a minute (default 30), `/health` excepted.
- Per day: `DAILY_SAM_FRAMES` frames sent to SAM (default 60000, about $12 at $0.20 per 1,000),
  `DAILY_SPARK_CALLS` Muse Spark calls (default 3000).
- At once: `MAX_REALTIME_SOCKETS` open realtime transcription sockets (default 4).

Over a cap, the answer is HTTP 429 {"error": "budget", "detail": "..."}; a stream that has already
started sends the same object as its final JSON line. The phone treats it like being offline.
"""

from __future__ import annotations

import os
import threading
import time
from collections import deque
from collections.abc import Callable
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

try:
    CENTRAL = ZoneInfo("America/Chicago")
except ZoneInfoNotFoundError:  # no tz database on the machine: standard time, close enough for a reset
    CENTRAL = timezone(timedelta(hours=-6), "CST")

ERROR = "budget"


class BudgetExceeded(RuntimeError):
    """A cap is reached; main.py turns it into the 429."""

    def __init__(self, detail: str):
        super().__init__(detail)
        self.detail = detail

    def body(self) -> dict[str, str]:
        return {"error": ERROR, "detail": self.detail}


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    try:
        return int(raw) if raw else default
    except ValueError:
        return default


class Budget:
    """The counters. `now` is injectable so the tests can move the clock."""

    def __init__(
        self,
        *,
        per_ip_per_minute: int = 30,
        daily_sam_frames: int = 60_000,
        daily_spark_calls: int = 3_000,
        max_realtime_sockets: int = 4,
        now: Callable[[], float] = time.time,
    ):
        self.per_ip_per_minute = per_ip_per_minute
        self.daily_sam_frames = daily_sam_frames
        self.daily_spark_calls = daily_spark_calls
        self.max_realtime_sockets = max_realtime_sockets
        self.now = now
        self._lock = threading.Lock()
        self._day = self._today()
        self._sam_frames = 0
        self._spark_calls = 0
        self._sockets = 0
        self._hits: dict[str, deque[float]] = {}

    @classmethod
    def from_env(cls) -> Budget:
        return cls(
            per_ip_per_minute=_env_int("PER_IP_PER_MINUTE", 30),
            daily_sam_frames=_env_int("DAILY_SAM_FRAMES", 60_000),
            daily_spark_calls=_env_int("DAILY_SPARK_CALLS", 3_000),
            max_realtime_sockets=_env_int("MAX_REALTIME_SOCKETS", 4),
        )

    # -- the day ---------------------------------------------------------------------------------

    def _today(self) -> str:
        return datetime.fromtimestamp(self.now(), CENTRAL).date().isoformat()

    def _roll(self) -> None:
        """Called with the lock held: a new Central day clears the daily counters."""
        today = self._today()
        if today != self._day:
            self._day = today
            self._sam_frames = 0
            self._spark_calls = 0

    # -- per IP ------------------------------------------------------------------------------------

    def check_ip(self, ip: str) -> None:
        """One more request from `ip`; raises once it has made more than the limit in the last minute."""
        if self.per_ip_per_minute <= 0:
            return
        t = self.now()
        with self._lock:
            hits = self._hits.setdefault(ip, deque())
            while hits and hits[0] <= t - 60:
                hits.popleft()
            if len(hits) >= self.per_ip_per_minute:
                raise BudgetExceeded(f"more than {self.per_ip_per_minute} requests a minute from one address")
            hits.append(t)
            if len(self._hits) > 10_000:  # a flood of addresses: forget the quiet ones
                for key in [k for k, v in self._hits.items() if not v or v[-1] <= t - 60]:
                    del self._hits[key]

    # -- per day -----------------------------------------------------------------------------------

    def charge_spark(self, calls: int = 1) -> None:
        with self._lock:
            self._roll()
            if self._spark_calls + calls > self.daily_spark_calls:
                raise BudgetExceeded("Setecho's demo budget for Muse Spark is used up for today")
            self._spark_calls += calls

    def charge_sam_frames(self, frames: int) -> None:
        with self._lock:
            self._roll()
            if self._sam_frames + frames > self.daily_sam_frames:
                raise BudgetExceeded("Setecho's demo budget for SAM is used up for today")
            self._sam_frames += frames

    # -- at once -----------------------------------------------------------------------------------

    def acquire_socket(self) -> bool:
        with self._lock:
            if self._sockets >= self.max_realtime_sockets:
                return False
            self._sockets += 1
            return True

    def release_socket(self) -> None:
        with self._lock:
            self._sockets = max(0, self._sockets - 1)

    # -- for /health -------------------------------------------------------------------------------

    def snapshot(self) -> dict[str, int | str]:
        with self._lock:
            self._roll()
            return {
                "day": self._day,
                "samFrames": self._sam_frames,
                "samFramesCap": self.daily_sam_frames,
                "sparkCalls": self._spark_calls,
                "sparkCallsCap": self.daily_spark_calls,
                "realtimeSockets": self._sockets,
                "realtimeSocketsCap": self.max_realtime_sockets,
                "perIpPerMinute": self.per_ip_per_minute,
            }


budget = Budget.from_env()

EXEMPT_PATHS = frozenset({"/health", "/docs", "/openapi.json"})


def client_ip(headers: Callable[[str], str | None], fallback: str | None) -> str:
    """Fly puts the caller's address in Fly-Client-IP; behind another proxy, the first X-Forwarded-For."""
    direct = headers("fly-client-ip")
    if direct:
        return direct.strip()
    forwarded = headers("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return fallback or "unknown"
