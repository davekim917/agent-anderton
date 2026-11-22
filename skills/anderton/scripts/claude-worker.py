#!/usr/bin/env python3
"""Read final reports from a registered Claude worker's native transcript."""

import argparse
import datetime
import json
import os
from pathlib import Path
import re
import sys

REPORT = re.compile(r"^(RESULT|QUESTION|BLOCKED|ANSWER):[ \t]*\S")


def transcript_events(worker):
    identity = worker.get("claudeSession") or {}
    if "transcript" not in identity:
        return
    transcript = Path(identity["transcript"])
    if transcript.name != f"{identity['id']}.jsonl":
        raise ValueError("Claude worker's transcript identity changed")
    with transcript.open() as file:
        for line in file:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                if not line.endswith("\n"):
                    break
                raise
            if event.get("sessionId") != identity["id"] or event.get("isSidechain", False):
                continue
            yield event


def final_replies(worker):
    for event in transcript_events(worker):
        if event.get("type") != "assistant" or event.get("message", {}).get("stop_reason") != "end_turn":
            continue
        text = "\n".join(block["text"] for block in event["message"]["content"] if block["type"] == "text")
        yield event["uuid"], event["timestamp"], text.strip()


def instant(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def sweep(worker, replies):
    identity = worker.get("claudeSession") or {}
    if "id" not in identity:
        return
    bookmark = f"claude-{identity['id']}.json"
    previous = Path(os.environ["ANDERTON_PROBE_STATE"]) / bookmark
    stage = Path(os.environ["ANDERTON_PROBE_STAGE"]) / bookmark
    checkpoint = json.loads(previous.read_text()) if previous.exists() else None
    passed_checkpoint = checkpoint is None
    started = instant(worker["startedAt"])
    latest = checkpoint
    for event_id, timestamp, text in replies:
        if event_id == checkpoint:
            passed_checkpoint = True
            continue
        if timestamp and instant(timestamp) < started:
            continue
        latest = event_id
        if passed_checkpoint and REPORT.match(text):
            print(f"{worker['name']} (Claude {identity['id']}) report:\n{text[:2000]}")
    if not passed_checkpoint:
        raise ValueError("Claude transcript no longer contains its report bookmark")
    if latest is not None and latest != checkpoint:
        stage.write_text(json.dumps(latest) + "\n")


def transcript_contains_notice(worker, marker):
    for event in transcript_events(worker):
        if event.get("type") == "queue-operation" and event.get("operation") == "enqueue":
            if marker in str(event.get("content", "")):
                return True
        if event.get("type") != "user" or (event.get("origin") or {}).get("kind") != "task-notification":
            continue
        content = event.get("message", {}).get("content", "")
        if isinstance(content, str) and marker in content:
            return True
    return False


def acknowledged(worker):
    direction = worker.get("claudeDirection") or {}
    return (bool(direction.get("attemptedAt"))
            and transcript_contains_notice(worker, f"Direction {direction['id']} from your Anderton."))


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("sweep", "output", "acknowledged"):
        commands.add_parser(name).add_argument("record", type=Path)
    peer = commands.add_parser("peer-received")
    peer.add_argument("transcript", type=Path)
    peer.add_argument("session")
    peer.add_argument("peer")
    args = parser.parse_args()
    if args.command == "peer-received":
        worker = {"claudeSession": {"id": args.session, "transcript": str(args.transcript)}}
        return 0 if transcript_contains_notice(worker, f"Peer message {args.peer} from Anderton ") else 3
    worker = json.loads(args.record.read_text())
    if args.command == "acknowledged":
        return 0 if acknowledged(worker) else 3
    replies = final_replies(worker)
    if args.command == "sweep":
        sweep(worker, replies)
    else:
        last = None
        for last in replies:
            pass
        if last is None:
            raise ValueError("No verified final reply for this Claude worker")
        print(f"Claude session {worker['claudeSession']['id']} final reply:\n{last[2][:2000]}")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, KeyError, ValueError, TypeError) as error:
        print(f"Claude worker: {error}", file=sys.stderr)
        sys.exit(1)
