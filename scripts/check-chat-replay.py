#!/usr/bin/env python3
"""Assert an interactive chat replay completed without a main-thread stall.

After opening a card discussion, asking for analysis, and sending a follow-up,
run with --since <UTC time before the first question>. UI interaction remains
external to this check; it never sends a prompt or changes application data.
"""
import argparse
import datetime
import json
import os
from pathlib import Path


def timestamp(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--since", required=True, type=timestamp)
parser.add_argument("--turns", type=int, default=2)
args = parser.parse_args()
home = Path(os.environ.get("NOTELING_HOME") or os.environ.get("FAMILIAR_HOME") or str(Path.home() / ".noteling"))
directory = home / "diagnostics/main-thread"
events = []
for filename in ("events.previous.jsonl", "events.jsonl"):
    path = directory / filename
    if path.exists():
        events.extend(json.loads(line) for line in path.read_text().splitlines() if line.strip())
events = [event for event in events if timestamp(event["at"]) >= args.since]
stalls = [event for event in events if event["kind"] == "main-thread-stalled"]
completed = sum(event.get("phase") == "requestFinished" and event["kind"] == "phase" for event in events)
assert not stalls, f"Chat froze during replay: {len(stalls)} stall(s), last phase {stalls[-1].get('phase')}"
assert completed >= args.turns, f"Only {completed}/{args.turns} chat turns completed"
print(f"PASS: {completed} completed chat turns and no main-thread stalls since {args.since.isoformat()}")
