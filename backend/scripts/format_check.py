"""Format check (HANDOFF.md §9, block 1): render the check-in from the imported form and compare it
line for line with a real past check-in the human pasted into backend/private/checkin/past.txt.

  uv run python -m scripts.format_check [--template tests/fixtures/spark/form_coach_form.json] [--past private/checkin/past.txt]

Offline. Prints every line that differs (label, order, carried block) and the plan message as
its own message. The past check-in never leaves backend/private/.
"""

from __future__ import annotations

import argparse
import difflib
import json
import re
from pathlib import Path

from app import checkin
from app.schemas import CheckInTemplateOut, to_template

ROOT = Path(__file__).resolve().parents[1]


def labels_only(text: str) -> list[str]:
    """Each line up to its colon, so answers (which differ every week) don't count."""
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        out.append(re.sub(r":\s.*$", ":", line) if ":" in line else line)
    return out


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--template", default=str(ROOT / "tests/fixtures/spark/form_coach_form.json"))
    p.add_argument("--past", default=str(ROOT / "private/checkin/past.txt"))
    args = p.parse_args()
    past_path = Path(args.past)
    if not past_path.exists():
        print(f"No past check-in at {past_path}. Paste one there (it is gitignored) and rerun.")
        return
    raw = json.loads(Path(args.template).read_text())["raw"]
    template = to_template(CheckInTemplateOut.model_validate(raw))
    draft = checkin.CheckInDraft(id="check", weekStart="2026-10-23", weekEnd="2026-10-30", answers=[])
    messages = checkin.render_messages(template, draft)
    rendered = "\n\n".join(messages)
    past = past_path.read_text()
    ours = labels_only(rendered)
    theirs = labels_only(past)
    diff = list(difflib.unified_diff(theirs, ours, "his check-in", "our render", lineterm=""))
    print(
        f"{len(messages)} message(s): plan message {'present' if len(messages) == 2 else 'absent'}, {len(ours)} lines vs {len(theirs)} in his."
    )
    if not diff:
        print("Labels, order and carried blocks match line for line.")
        return
    print("\n".join(diff))


if __name__ == "__main__":
    main()
