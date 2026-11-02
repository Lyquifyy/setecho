"""`make replay` on the saved SAM 3.1 sets: offline, and the same count `/sets/count` would give."""

import json

from app import reps
from scripts import replay

FIXTURES = sorted(replay.FIXTURES.glob("*.json"))


def test_replay_counts_every_saved_set_offline(capsys):
    results = replay.main([])
    out = capsys.readouterr().out
    assert len(results) == len(FIXTURES) >= 2
    for result in results:
        assert result["trackFound"]
        assert result["reps"] == result["handCount"]
        assert len(result["repTimes"]) == len(result["repSpeeds"]) == result["reps"]
        assert result["velocityLossPct"] is not None
        assert result["name"] in out
        assert f"hand count {result['handCount']}   SAM 3.1 count {result['reps']}" in out


def test_replay_is_the_count_endpoints_call():
    """The same `reps.count` on the same Track that `/sets/count` builds, so the two never drift."""
    path = FIXTURES[0]
    result = replay.replay(path)
    direct = reps.count(replay.track_from_fixture(json.loads(path.read_text())))
    assert result["reps"] == direct.reps
    assert result["repTimes"] == direct.rep_times
    assert result["repSpeeds"] == direct.rep_speeds
    assert result["velocityLossPct"] == direct.velocity_loss_pct
    assert result["confidence"] == direct.confidence
