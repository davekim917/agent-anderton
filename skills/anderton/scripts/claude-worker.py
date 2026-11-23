#!/usr/bin/env python3
"""Read milestone reports from a Claude worker's native transcript."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

REPORT = re.compile(r"^(RESULT|QUESTION|BLOCKED|ANSWER):\s*\S")

def report_text(text):
    return text.strip().lstrip(" \t*_#>`-")


def transcript_events(worker):
    identity = worker.get("claudeSession") or {}
    if "transcript" not in identity:
        return
    transcript = Path(identity["transcript"])
    if transcript.name != f"{identity['id']}.jsonl":
        raise ValueError("Claude worker's transcript identity changed")
    if not transcript.exists():
        return
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


def instant(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))

def legacy_launch_matches(worker):
    if not worker.get("spawner"):
        return False
    brief = f'You are a worker the Anderton session "{worker["spawner"]}" started for the task above, in {worker["dir"]}.'
    started = instant(worker["startedAt"])
    # Older tmux launches wrote the record after starting the client in the new window.
    if worker.get("launcher") == "tmux":
        started -= datetime.timedelta(minutes=1)
    for event in transcript_events(worker):
        if event.get("type") != "user":
            continue
        content = event.get("message", {}).get("content")
        if isinstance(content, str):
            return (event.get("cwd") == worker["dir"] and instant(event["timestamp"]) >= started
                    and brief in content.splitlines())
    return False


def native_report_cutoff(worker, claim):
    if claim.get("provider") != "codex" or worker.get("spawnerProvider", "claude") != "claude":
        return None
    previous = claim.get("claudeReportPreviousHolder") or {}
    if "spawnerScope" in worker:
        if worker["spawnerScope"] != claim.get("scope"):
            return None
    elif not previous.get("sessionId") or worker.get("spawnerSession") != previous["sessionId"]:
        return None
    report_since = claim.get("claudeReportSince") or claim.get("claimedAt")
    return instant(report_since) if report_since else None


def legacy_worker_transcript(worker, home, cutoff):
    matches = []
    for path in (home / "projects").glob("*/*.jsonl"):
        if not re.fullmatch(r"[a-zA-Z0-9-]+", path.stem):
            continue
        identity = {"id": path.stem, "transcript": str(path)}
        try:
            if path.stat().st_mtime + 1 >= cutoff.timestamp() and legacy_launch_matches({**worker, "claudeSession": identity}):
                matches.append(identity)
        except (OSError, KeyError, TypeError, ValueError):
            continue
    return matches[0] if len(matches) == 1 else None


def route_path(routes, session, tool_id):
    if not all(isinstance(value, str) and re.fullmatch(r"[a-zA-Z0-9_-]+", value) for value in (session, tool_id)):
        raise ValueError("Invalid native route identity")
    return routes / session / f"{tool_id}.json"


def route_receipt(worker, claim, to, text):
    if not isinstance(to, str) or not isinstance(text, str):
        raise ValueError("Invalid native report")
    return {
        "worker": worker["name"], "root": claim["root"], "scope": claim.get("scope"),
        "to": to, "digest": hashlib.sha256(text.encode()).hexdigest(),
    }


def record_native_route(worker, claim, routes, hook):
    if claim.get("provider") != "codex" or hook.get("hook_event_name") != "PreToolUse":
        raise ValueError("Native route requires a Codex owner and a SendMessage attempt")
    path = route_path(routes, hook["session_id"], hook["tool_use_id"])
    payload = route_receipt(worker, claim, hook["tool_input"]["to"], hook["tool_input"]["message"])
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as file:
        temporary = Path(file.name)
        try:
            json.dump(payload, file)
            file.close()
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def routed_native_report(worker, claim, routes, tool, to, text):
    if routes is None or claim.get("provider") != "codex":
        return False
    try:
        path = route_path(routes, worker["claudeSession"]["id"], tool)
        return json.loads(path.read_text()) == route_receipt(worker, claim, to, text)
    except FileNotFoundError:
        return False


def reports_and_replies(worker, claim=None, routes=None):
    turn = None
    cutoff = native_report_cutoff(worker, claim) if claim else None
    previous = (claim or {}).get("claudeReportPreviousHolder") or {}
    old_pid = previous.get("pid") if worker.get("spawnerSession") == previous.get("sessionId") else None
    earlier_sends = {}
    delivered = set()
    for event in transcript_events(worker):
        if event.get("type") == "user" and not event.get("isMeta"):
            content = event.get("message", {}).get("content", "")
            if isinstance(content, str) or (isinstance(content, list) and
                                            any(block["type"] != "tool_result" for block in content)):
                turn = event.get("uuid")
                earlier_sends.clear()
                delivered.clear()
            result = event.get("toolUseResult")
            if (cutoff is not None and earlier_sends and isinstance(content, list) and isinstance(result, dict)
                and result.get("success") is True and instant(event["timestamp"]) < cutoff):
                for block in content:
                    tool_id = block.get("tool_use_id")
                    if tool_id in earlier_sends and not block.get("is_error"):
                        delivered.add(earlier_sends[tool_id])
        if event.get("type") != "assistant":
            continue
        message = event["message"]
        event_id, timestamp = event["uuid"], event["timestamp"]
        if message.get("stop_reason") == "end_turn":
            text = "\n".join(block["text"] for block in message["content"] if block["type"] == "text")
            yield event_id, timestamp, text, False, turn, report_text(text) not in delivered
        for block in message["content"]:
            if block["type"] != "tool_use" or block.get("name") != "SendMessage":
                continue
            args = block.get("input", {})
            to, text = args.get("to"), args.get("message")
            if not isinstance(to, str) or not isinstance(text, str):
                continue
            if old_pid and cutoff is not None and instant(timestamp) < cutoff and to.startswith("uds:") and to.endswith(f"/{old_pid}.sock"):
                earlier_sends[block["id"]] = report_text(text)
            routed = routed_native_report(worker, claim, routes, block["id"], to, text)
            yield f'{event_id}:{block["id"]}', timestamp, text, True, turn, routed


def sweep(worker, claim, routes):
    for identity in worker.get("claudePreviousSessions", []):
        if Path(identity["transcript"]).is_file():
            sweep_transcript({**worker, "claudeSession": identity}, claim, routes)
    sweep_transcript(worker, claim, routes)


def sweep_transcript(worker, claim, routes):
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
    native = set()
    last_turn = None
    for event_id, timestamp, text, sent, turn, eligible in reports_and_replies(worker, claim, routes):
        if turn != last_turn:
            native.clear()
            last_turn = turn
        if event_id == checkpoint:
            passed_checkpoint = True
        if timestamp and instant(timestamp) < started:
            continue
        if not eligible:
            continue
        text = report_text(text)
        duplicate = text in native
        if sent and REPORT.match(text):
            native.add(text)
        if event_id == checkpoint:
            continue
        if not passed_checkpoint:
            continue
        latest = event_id
        if REPORT.match(text) and not duplicate:
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
    for name in ("output", "acknowledged"):
        commands.add_parser(name).add_argument("record", type=Path)
    scan = commands.add_parser("sweep")
    scan.add_argument("record", type=Path)
    scan.add_argument("--claim", type=Path)
    scan.add_argument("--legacy-home", type=Path)
    route = commands.add_parser("record-native-route")
    route.add_argument("record", type=Path)
    route.add_argument("claim", type=Path)
    legacy = commands.add_parser("legacy-launch-matches")
    legacy.add_argument("record", type=Path)
    legacy.add_argument("transcript", type=Path)
    peer = commands.add_parser("peer-received")
    peer.add_argument("transcript", type=Path)
    peer.add_argument("session")
    peer.add_argument("peer")
    args = parser.parse_args()
    if args.command == "peer-received":
        worker = {"claudeSession": {"id": args.session, "transcript": str(args.transcript)}}
        return 0 if transcript_contains_notice(worker, f"Peer message {args.peer} from Anderton ") else 3
    worker = json.loads(args.record.read_text())
    if args.command == "record-native-route":
        claim = json.loads(args.claim.read_text())
        record_native_route(worker, claim, args.claim.parent / "reports/routes", json.load(sys.stdin))
        return 0
    if args.command == "legacy-launch-matches":
        worker["claudeSession"] = {"id": args.transcript.stem, "transcript": str(args.transcript)}
        return 0 if legacy_launch_matches(worker) else 3
    if args.command == "acknowledged":
        return 0 if acknowledged(worker) else 3
    if args.command == "sweep":
        claim = json.loads(args.claim.read_text()) if args.claim else {}
        if args.legacy_home:
            if claim.get("provider") != "codex":
                return 0
            cutoff = native_report_cutoff(worker, claim) or instant(worker["startedAt"])
            identity = legacy_worker_transcript(worker, args.legacy_home, cutoff)
            if not identity:
                return 0
            worker["claudeSession"] = identity
        sweep(worker, claim, args.claim.parent / "reports/routes" if args.claim else None)
    else:
        last = None
        for _, _, text, sent, _, _ in reports_and_replies(worker):
            if not sent:
                last = text
        if last is None:
            raise ValueError("No verified final reply for this Claude worker")
        print(f"Claude session {worker['claudeSession']['id']} final reply:\n{last[:2000]}")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, KeyError, ValueError, TypeError) as error:
        print(f"Claude worker: {error}", file=sys.stderr)
        sys.exit(1)
