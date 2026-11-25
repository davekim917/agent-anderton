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
NON_CLAUDE = ("codex", "agy")

def report_text(text):
    return text.strip().lstrip(" \t*_#>`-")


def transcript_events(worker, strict=False):
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
                if not line.endswith("\n") and not strict:
                    break
                raise ValueError(f"its transcript {transcript} ends in a record that is not complete JSON")
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
    if claim.get("provider") not in NON_CLAUDE or worker.get("spawnerProvider", "claude") != "claude":
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
    if claim.get("provider") not in NON_CLAUDE or hook.get("hook_event_name") != "PreToolUse":
        raise ValueError("Native route requires a Codex or agy owner and a SendMessage attempt")
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
    if routes is None or claim.get("provider") not in NON_CLAUDE:
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
    native_kinds = set()
    last_turn = None
    for event_id, timestamp, text, sent, turn, eligible in reports_and_replies(worker, claim, routes):
        if turn != last_turn:
            native.clear()
            native_kinds.clear()
            last_turn = turn
        if event_id == checkpoint:
            passed_checkpoint = True
        if timestamp and instant(timestamp) < started:
            continue
        if not eligible:
            continue
        text = report_text(text)
        kind = REPORT.match(text)
        # A final reply that restates, in other words, a milestone this turn already sent natively.
        duplicate = text in native or (not sent and kind is not None and kind.group(1) in native_kinds)
        if sent and kind:
            native.add(text)
            native_kinds.add(kind.group(1))
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


# Claude Code wraps a cross-session message so when the transcript entry carries no origin.
WRAPPED_PEER = re.compile(r'^Another Claude session sent a message:\s*<cross-session-message from="(?P<sender>[^"]*)"'
                          r'(?: from-name="(?P<name>[^"]*)")?[^>]*>\s*(?P<body>[\s\S]*?)(?:</cross-session-message>|$)')
# What Claude Code writes as a user entry without a person having written it: a shell command's output (its input line
# is the person's), the marker an interruption leaves, a deferred tool's load.
INJECTED = ("<bash-stdout>", "<bash-stderr>", "<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>",
            "[Request interrupted by user", "Tool loaded.")
# A sub-agent's hand-back and an agent-team teammate's message are the worker's own helpers answering it.
DELEGATED = re.compile(r"^(Another Claude session sent a message:\s*)?<(agent-message|teammate-message)[ >]")
# The wrappers waiting.sh also strips before it judges a user entry a person's.
HARNESS_WRAPPER = re.compile(r"<(?P<t>task-notification|system|system-reminder|local-command-stdout|local-command-caveat)>"
                             r"[\s\S]*?</(?P=t)>")
SOCKET_PID = re.compile(r"^uds:.*/(\d+)\.sock$")


class Unreadable(ValueError):
    pass


def first_line(text):
    for line in text.splitlines():
        line = line.strip()
        if line:
            return line[:200]
    return "(no text)"


def entry_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(block.get("text", "") for block in content
                         if isinstance(block, dict) and block.get("type") == "text")
    return ""


class Anderton:
    """The worker's own Anderton, as its record knows it: the name it reports to, and the processes the record's
    spawner session ran as. A message counts as its own only by the sending process Claude Code verified, never by a
    display name."""

    def __init__(self, name, processes):
        self.name = name
        self.processes = {str(pid): start for pid, start in processes if pid}

    def sent(self, pid, start):
        if not pid or str(pid) not in self.processes:
            return False
        known = self.processes[str(pid)]
        return known is None or start is None or str(known) == str(start)

    def addressed(self, to):
        if not isinstance(to, str):
            return False
        if self.name and (to == self.name or to.startswith(self.name + " [")):
            return True
        match = SOCKET_PID.match(to)
        return bool(match and match.group(1) in self.processes)


def inbound_message(origin, text, meta, anderton, launch):
    """(sender, text) for a message someone other than the worker's own Anderton sent it, else None. Where the entry
    came from decides first: a person's entry counts whatever it says, except the launch brief itself."""
    kind = origin.get("kind")
    if kind == "human":
        if launch.pop("brief", None) and launch["line"] in text.splitlines():
            return None
        return "the user", text
    if kind in {"task-notification", "auto-continuation"}:
        return None
    bare = HARNESS_WRAPPER.sub("", text).strip()
    if DELEGATED.match(bare):
        return None
    if kind == "peer":
        if origin.get("handback") or anderton.sent(origin.get("verifiedPeerPid"), origin.get("verifiedPeerProcStart")):
            return None
        body = origin.get("body")
        if not isinstance(body, str):
            wrapped = WRAPPED_PEER.match(text.strip())
            body = wrapped.group("body") if wrapped else text
        return origin.get("name") or origin.get("from") or "another session", body
    if kind is not None:
        return None if meta else (f"an unrecognised {kind} entry", text)
    if meta or not bare or bare.startswith(INJECTED):
        return None
    if launch.pop("brief", None) and launch["line"] in text.splitlines():
        return None
    wrapped = WRAPPED_PEER.match(bare)
    if wrapped:
        # No origin: Claude Code verified no sender, so not even the Anderton's name in it is taken on trust.
        return wrapped.group("name") or wrapped.group("sender"), wrapped.group("body")
    return "the user", text


def replayed(seen, event, text):
    """True for a message Claude Code appended again under a new entry id: it keeps the time it first arrived."""
    key = (event.get("timestamp"), text)
    if key in seen["messages"]:
        return True
    seen["messages"].add(key)
    return False


def delivered(event, block):
    """True only on evidence the send arrived: SendMessage's result says success."""
    if block.get("is_error"):
        return False
    result = event.get("toolUseResult")
    if isinstance(result, dict) and "success" in result:
        return result["success"] is True
    content = json.dumps(block.get("content"))
    if re.search(r'\\*"success\\*"\s*:\s*false', content):
        return False
    return bool(re.search(r'\\*"success\\*"\s*:\s*true', content))


def scan_inbound(events, anderton, launch, final_replies_report, held, seen):
    """Walks one transcript in order, keeping in held the messages that arrived since the worker's last report: a message
    it delivered to its Anderton, or under a Codex Anderton, which reads its final replies, one that opens with a kind.
    An entry, or a tool call, Claude Code appends again (a resumed or forked session) counts once, where it first
    appeared."""
    sends = {}
    latest = None
    for event in events:
        if event.get("uuid"):
            if event["uuid"] in seen["entries"]:
                continue
            seen["entries"].add(event["uuid"])
        latest = event.get("timestamp") or latest
        kind = event.get("type")
        if kind == "assistant":
            message = event.get("message") or {}
            for block in message.get("content") or []:
                if block.get("type") == "tool_use" and block.get("name") == "SendMessage":
                    if block.get("id") in seen["tools"]:
                        continue
                    seen["tools"].add(block.get("id"))
                    args = block.get("input") or {}
                    if isinstance(args.get("message"), str) and args["message"].strip() and anderton.addressed(args.get("to")):
                        sends[block.get("id")] = True
            if final_replies_report and message.get("stop_reason") == "end_turn" and \
                    REPORT.match(report_text(entry_text(message.get("content")))):
                held.clear()
            continue
        if kind == "attachment":
            attachment = event.get("attachment") or {}
            if attachment.get("type") != "queued_command":
                continue
            prompt = attachment.get("prompt")
            text = prompt if isinstance(prompt, str) else entry_text(prompt)
            if replayed(seen, event, text):
                continue
            found = inbound_message(attachment.get("origin") or {}, text, False, anderton, launch)
        elif kind == "user":
            content = (event.get("message") or {}).get("content", "")
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_result" and sends.pop(block.get("tool_use_id"), None) \
                            and delivered(event, block):
                        held.clear()
                if all(isinstance(block, dict) and block.get("type") == "tool_result" for block in content):
                    continue
            if event.get("isCompactSummary") or replayed(seen, event, entry_text(content)):
                continue
            found = inbound_message(event.get("origin") or {}, entry_text(content), bool(event.get("isMeta")), anderton, launch)
        else:
            continue
        if found:
            held.append({"at": event.get("timestamp"), "from": found[0], "line": first_line(found[1])})
    return latest


def worker_identities(worker, home):
    identities = list(worker.get("claudePreviousSessions") or [])
    if worker.get("claudeSession"):
        identities.append(worker["claudeSession"])
    if not identities and worker.get("claudeLaunchId"):
        launch = worker["claudeLaunchId"]
        if not re.fullmatch(r"[a-zA-Z0-9-]+", launch):
            raise Unreadable("the record's launch id is not a session id")
        found = sorted((home / "projects").glob(f"*/{launch}.jsonl"))
        identities = [{"id": launch, "transcript": str(path)} for path in found[:1]] if len(found) == 1 else []
    if not identities and worker.get("dir") and worker.get("spawner"):
        # A record from before launch ids: the one transcript whose brief names this worker and its worktree.
        legacy = {"startedAt": "1970-01-01T00:00:00Z", **worker}
        found = legacy_worker_transcript(legacy, home, instant(legacy["startedAt"]))
        identities = [found] if found else []
    if not identities:
        raise Unreadable("its record names no transcript, and none was found for its launch")
    for identity in identities:
        if not identity.get("id") or not identity.get("transcript"):
            raise Unreadable("its record names a session without its transcript")
        if not Path(identity["transcript"]).is_file():
            raise Unreadable(f"its transcript {identity['transcript']} is missing")
    return identities


def anderton_of(worker, home):
    """The processes the record's spawner session ran as, from Claude Code's registry of sessions."""
    processes = []
    spawner_session = worker.get("spawnerSession")
    if spawner_session:
        for entry in (home / "sessions").glob("*.json"):
            try:
                registered = json.loads(entry.read_text())
            except (OSError, ValueError):
                continue
            if registered.get("sessionId") == spawner_session:
                processes.append((registered.get("pid") or entry.stem, registered.get("procStart")))
    return Anderton(worker.get("spawner"), processes)


def reviewed_instant(value):
    """The instant a --reviewed-through value names: ISO-8601 with a zone, and not in the future."""
    if not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d(:\d\d(\.\d+)?)?(Z|[+-]\d\d:\d\d)", value or ""):
        raise ValueError(f"--reviewed-through takes an ISO-8601 time with its zone, such as 2026-01-31T14:05:00Z, not '{value}'")
    at = instant(value)
    if at > datetime.datetime.now(datetime.timezone.utc):
        raise ValueError(f"--reviewed-through {value} is in the future: it can only confirm what has already arrived")
    return at


def unreviewed(held, through, latest):
    """The held messages after through. One without a time takes the transcript's latest, so a review through then
    covers it."""
    kept = []
    for message in held:
        message["at"] = message["at"] or latest
        if through is None or message["at"] is None or instant(message["at"]) > through:
            kept.append(message)
    return kept


def inbound_since_report(worker, home, through):
    anderton = anderton_of(worker, home)
    launch = {"brief": True, "line": f'You are a worker the Anderton session "{worker.get("spawner")}" started for the task '
                                     f'above, in {worker.get("dir")}.'}
    final_replies_report = worker.get("reportTransport") == "transcript" or worker.get("spawnerProvider") in NON_CLAUDE
    held = []
    seen = {"entries": set(), "tools": set(), "messages": set()}
    latest = None
    for identity in worker_identities(worker, home):
        latest = scan_inbound(transcript_events({**worker, "claudeSession": identity}, strict=True), anderton, launch,
                              final_replies_report, held, seen) or latest
    return unreviewed(held, through, latest)

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
    inbound = commands.add_parser("inbound-since-report")
    inbound.add_argument("record", type=Path)
    inbound.add_argument("--home", type=Path, required=True)
    inbound.add_argument("--reviewed-through")
    reviewed = commands.add_parser("reviewed-time")
    reviewed.add_argument("value")
    args = parser.parse_args()
    if args.command == "reviewed-time":
        reviewed_instant(args.value)
        return 0
    if args.command == "inbound-since-report":
        through = reviewed_instant(args.reviewed_through) if args.reviewed_through else None
        worker = json.loads(args.record.read_text())
        held = inbound_since_report(worker, args.home, through)
        print(json.dumps({"messages": held}))
        return 4 if held else 0
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
            if claim.get("provider") not in NON_CLAUDE:
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
