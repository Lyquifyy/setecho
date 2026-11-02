"""Every test shares one client address, so the per-address limit (budget.py) would trip halfway
through the suite. It's off here; test_budget.py puts its own small limiter in for its tests."""

import pytest

from app import budget


@pytest.fixture(autouse=True)
def _no_per_ip_limit():
    before = budget.budget.per_ip_per_minute
    budget.budget.per_ip_per_minute = 0
    yield
    budget.budget.per_ip_per_minute = before
