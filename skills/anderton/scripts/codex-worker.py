#!/usr/bin/env python3
"""Read Codex workers through the local daemon's WebSocket JSON-RPC endpoint."""

import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid

MAX_MESSAGE = 16 * 1024 * 1024
REQUEST_SECONDS = 5
# Codex answers a thread/list filtered by cwd by scanning its whole thread history: seconds per few hundred threads.
DIRECTORY_LIST_SECONDS = 60
# A launch's thread counts from this long before the recorded launch time, so a clock stepped back cannot hide it.
LAUNCH_MARGIN_SECONDS = 300
BLOCK_REMINDER_SECONDS = 300
# Longer than any request a lost connection can leave in flight: Codex.call waits REQUEST_SECONDS for a send's answer.
DIRECTION_LOST_AFTER_SECONDS = 60
# After dispatch removes a submission, give the new turn time to become visible.
DIRECTION_RECHECK_SECONDS = 3
DIRECTION_UNCONFIRMED_EXIT = 4
# Codex 0.171 caps the queue at 100 entries. Read them in one page to avoid shifts while it dispatches.
QUEUE_PAGE_SIZE = 100
# RFC 6455 requires the handshake GUID in uppercase ASCII.
HANDSHAKE_GUID = str(uuid.UUID("258eafa5-e914-47da-95ca-c5ab0dc85b11")).upper().encode("ascii")
REPORT = re.compile(r"^(RESULT|QUESTION|BLOCKED|ANSWER):[ \t]*\S")
# Codex's own usage-limit sentence starts so; only a failure with no structured kind is read from its words.
USAGE_LIMIT = re.compile(r"^You['\N{RIGHT SINGLE QUOTATION MARK}]ve hit your usage limit")
# A move that could not run (no account free, a daemon that did not start) is tried again after this long.
FAILOVER_RETRY_SECONDS = 600


def daemon_socket(home):
    return home / "app-server-control" / "app-server-control.sock"


class RequestRejected(ValueError):
    def __init__(self, method, error):
        super().__init__(f"{method}: {error['message']}")
        self.code = error["code"]


class Codex:
    def __init__(self, home):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(REQUEST_SECONDS)
        self.socket.connect(str(daemon_socket(home)))
        self.stream = self.socket.makefile("rb")
        self.request_id = 0

    def __enter__(self):
        try:
            self.initialize()
            return self
        except BaseException:
            self.__exit__()
            raise

    def __exit__(self, *_):
        self.stream.close()
        self.socket.close()

    def initialize(self):
        key = base64.b64encode(os.urandom(16))
        self.socket.sendall(
            b"GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
            b"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: "
            + key + b"\r\n\r\n"
        )
        if not self.stream.readline(8192).startswith(b"HTTP/1.1 101 "):
            raise ValueError("Codex daemon refused the WebSocket upgrade")
        headers = {}
        for _ in range(32):
            line = self.stream.readline(8192)
            if line == b"\r\n":
                break
            name, sep, value = line.partition(b":")
            if not sep:
                raise ValueError("Invalid Codex daemon handshake")
            headers[name.lower()] = value.strip()
        else:
            raise ValueError("Too many Codex daemon handshake headers")
        expected = base64.b64encode(hashlib.sha1(key + HANDSHAKE_GUID).digest())
        if headers.get(b"sec-websocket-accept") != expected:
            raise ValueError("Invalid Codex daemon WebSocket signature")
        self.call("initialize", {"clientInfo": {
            "name": "agent-anderton", "title": None, "version": "1.0"
        }, "capabilities": {"experimentalApi": True, "requestAttestation": False}})
        self.send({"method": "initialized"})

    def frame(self, opcode, payload):
        size = len(payload)
        if size < 126:
            length = bytes([128 | size])
        elif size < 65536:
            length = b"\xfe" + struct.pack("!H", size)
        else:
            length = b"\xff" + struct.pack("!Q", size)
        mask = os.urandom(4)
        encoded = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.socket.sendall(bytes([128 | opcode]) + length + mask + encoded)

    def read(self, size):
        value = self.stream.read(size)
        if len(value) != size:
            raise ValueError("Codex daemon disconnected")
        return value

    def receive(self):
        pieces = []
        total = 0
        while True:
            header, size = self.read(2)
            opcode = header & 15
            if header & 112 or size & 128:
                raise ValueError("Unexpected Codex daemon WebSocket frame")
            if size >= 126:
                size = int.from_bytes(self.read(2 if size == 126 else 8), "big")
            total += size
            if total > MAX_MESSAGE:
                raise ValueError("Codex daemon response exceeds 16 MiB")
            payload = self.read(size)
            if opcode == 8:
                raise ValueError("Codex daemon closed the connection")
            if opcode == 9:
                self.frame(10, payload)
                continue
            if opcode == 10:
                continue
            if opcode != (0 if pieces else 1):
                raise ValueError("Unexpected Codex daemon WebSocket opcode")
            pieces.append(payload)
            if header & 128:
                return json.loads(b"".join(pieces))

    def send(self, message):
        self.frame(1, json.dumps(message).encode())

    def call(self, method, params, timeout=REQUEST_SECONDS):
        self.request_id += 1
        request = self.request_id
        self.send({"id": request, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.socket.settimeout(max(0.001, deadline - time.monotonic()))
            message = self.receive()
            if message.get("id") == request and "method" not in message:
                self.socket.settimeout(REQUEST_SECONDS)
                if "error" in message:
                    raise RequestRejected(method, message["error"])
                return message["result"]
        raise ValueError(f"Timed out waiting for {method}")

    def pages(self, method, timeout=REQUEST_SECONDS, **params):
        seen = set()
        while True:
            result = self.call(method, params, timeout=timeout)
            yield from result["data"]
            cursor = result.get("nextCursor")
            if not cursor:
                return
            if cursor in seen:
                raise ValueError(f"Repeated cursor from {method}")
            seen.add(cursor)
            params["cursor"] = cursor


def read_thread(client, worker):
    info = client.call("thread/read", {"threadId": worker["id"], "includeTurns": False})["thread"]
    if info["id"] != worker["id"] or Path(info["cwd"]).resolve() != Path(worker["dir"]).resolve():
        raise ValueError(f"Codex thread identity does not match worker {worker['name']}")
    return info


def thread_identity(client, thread_id):
    if str(uuid.UUID(thread_id)) != thread_id:
        raise ValueError("A canonical Codex thread UUID is required")
    thread = client.call("thread/read", {"threadId": thread_id, "includeTurns": False})["thread"]
    if (thread["id"] != thread_id or thread.get("parentThreadId") or thread.get("attachedToThreadId")
            or thread.get("ephemeral") or thread.get("canAcceptDirectInput") is False):
        raise ValueError("Expected the exact, addressable Codex thread of a full session")
    directory = Path(thread["cwd"])
    if not directory.is_absolute() or not directory.is_dir():
        raise ValueError("The Codex thread's directory does not exist")
    return {"id": thread_id, "dir": str(directory.resolve()), "name": thread.get("name") or thread_id}


def archived(client, thread):
    result = client.call("thread/list", {"archived": True, "includedThreadIds": [thread], "limit": 1})
    return any(entry["id"] == thread for entry in result["data"])


def claim_thread(claim):
    return {"id": claim["sessionId"], "dir": claim["dir"], "name": claim["name"]}


def started_with(client, thread, marker):
    """True or False for a visible first user message, and None until it is visible."""
    turns = client.call("thread/turns/list", {
        "threadId": thread, "sortDirection": "asc", "limit": 1, "itemsView": "notLoaded",
    })["data"]
    if not turns:
        return None
    for entry in client.pages("thread/items/list", threadId=thread, turnId=turns[0]["id"], limit=10):
        item = entry["item"]
        if item["type"] == "userMessage":
            parts = item["content"]
            if not parts:
                return None
            return any(part["type"] == "text" and part["text"].partition("\n")[0] == marker
                       for part in parts)
    return None


def threads_since(client, directory, since):
    """The directory's threads created at most LAUNCH_MARGIN_SECONDS before since, a Unix time, newest first."""
    # Without useStateDbOnly Codex rereads each listed thread's rollout file, a fraction of a second apiece, and a cwd
    # filter that matches nothing has it read them all. This list is answered from its index and stops at since.
    for thread in client.pages("thread/list", sortKey="created_at", sortDirection="desc", useStateDbOnly=True,
                               limit=20):
        if thread["createdAt"] < since - LAUNCH_MARGIN_SECONDS:
            return
        if Path(thread["cwd"]).resolve() == directory:
            yield thread


def find_thread(client, directory, after, token, since=None):
    marker = f"Anderton launch {uuid.UUID(token)}"
    match = None
    if since is None:
        threads = client.pages("thread/list", timeout=DIRECTORY_LIST_SECONDS, cwd=str(directory), limit=10)
    else:
        threads = threads_since(client, directory, since)
    for thread in threads:
        if Path(thread["cwd"]).resolve() != directory:
            raise ValueError("Codex daemon returned a thread in a different worktree")
        if thread["id"] == after:
            break
        if started_with(client, thread["id"], marker):
            if match is not None:
                raise ValueError("More than one Codex thread has this worker's launch marker")
            match = uuid.UUID(thread["id"])
    return match


def final_report(client, thread, turn):
    for entry in client.pages("thread/items/list", threadId=thread, turnId=turn,
                              sortDirection="desc", limit=10):
        item = entry["item"]
        if item["type"] == "agentMessage" and item.get("phase") in {"final_answer", None}:
            text = item["text"].strip()
            return text if REPORT.match(text) else None
    return None


def usage_limit(turn):
    """The message of a turn that failed at its account's usage limit, else None."""
    error = turn.get("error") or {}
    message = error.get("message") or ""
    if turn.get("status") != "failed":
        return None
    kind = error.get("codexErrorInfo")
    if kind is not None:
        return (message or "usage limit") if kind == "usageLimitExceeded" else None
    return message if USAGE_LIMIT.match(message) else None


# A loaded thread whose turn failed on an error stays systemError until its next turn starts; like idle, nothing runs.
QUIET_AFTER_FAILURE = {"idle", "notLoaded", "systemError"}


def failover_due(worker, turn):
    """True when the move of the worker's limited turn has not been tried, or failed long enough ago to retry. A moved
    thread brings its failed turn along, so the new account must not read it as its own limit."""
    tried = worker.get("codexFailover") or {}
    if tried.get("turn") != turn:
        return True
    if tried.get("moved") or tried.get("resumed"):
        return False
    if tried.get("stage") == "stopped":
        return True
    return time.time() - tried.get("at", 0) >= FAILOVER_RETRY_SECONDS


def limited_turn(client, worker):
    """(turn id, usage-limit message) of the worker's latest turn when its move is due and the thread waits idle on
    nothing, else None."""
    turns = client.call("thread/turns/list", {"threadId": worker["id"], "limit": 1, "itemsView": "notLoaded"})["data"]
    if not turns or not usage_limit(turns[0]) or not failover_due(worker, turns[0]["id"]):
        return None
    if client.call("thread/queue/list", {"threadId": worker["id"], "limit": 1})["data"]:
        return None
    if read_thread(client, worker)["status"]["type"] not in QUIET_AFTER_FAILURE:
        return None
    return turns[0]["id"], usage_limit(turns[0])


def resume_on(worker, home):
    """Resumes the worker's thread on the daemon of home, in its worktree; the caller records the home."""
    with Codex(home) as client:
        client.call("thread/resume", {"threadId": worker["id"], "cwd": worker["dir"], "excludeTurns": True},
                    timeout=60)
        read_thread(client, worker)


def is_inactive(client, worker, directions_only=False, reconcile=True):
    if reconcile:
        refresh_directions(client, worker)
    if any(not entry.get("neverArrived") for entry in pending_directions(worker)):
        return False
    if directions_only:
        return True
    if client.call("thread/queue/list", {"threadId": worker["id"], "limit": 1})["data"]:
        return False
    return read_thread(client, worker)["status"]["type"] in {"idle", "notLoaded"}


def pending_directions(worker):
    directions = worker.get("codexDirections", [])
    legacy = worker.pop("codexDirection", None)
    if legacy:
        directions = [{**legacy, "clientUserMessageId": legacy["id"]}, *directions]
        worker["codexDirections"] = directions
    return directions


def directions_seen(client, worker, directions):
    if not directions:
        return {}
    thread = worker["id"]
    remaining = {entry.get("clientUserMessageId", entry["id"]): entry for entry in directions}
    seen = {}
    # Read the queue before the turns. A dispatch that removes an entry between the reads will be in the
    # turns, leave the thread active, or be visible on a later look.
    for entry in client.pages("thread/queue/list", threadId=thread, limit=QUEUE_PAGE_SIZE):
        message = entry.get("clientUserMessageId")
        if message in remaining:
            seen[message] = ("queued", entry)
            del remaining[message]
            if not remaining:
                return seen
    missing = set(remaining)
    busy = False
    for turn in client.pages("thread/turns/list", threadId=thread, sortDirection="desc",
                             limit=20, itemsView="notLoaded"):
        busy = busy or turn["status"] == "inProgress"
        for entry in client.pages("thread/items/list", threadId=thread, turnId=turn["id"], limit=10):
            item = entry["item"]
            message = item.get("clientId")
            if item["type"] == "userMessage" and message in remaining:
                # A terminal turn with the user item is a receipt even if it was interrupted.
                finished = turn["status"] in {"completed", "interrupted", "failed"}
                seen[message] = ("finished" if finished else "running", None)
                del remaining[message]
        remaining = {message: entry for message, entry in remaining.items() if entry["previousTurn"] != turn["id"]}
        if not remaining:
            break
    missing.difference_update(seen)
    if missing:
        busy = busy or read_thread(client, worker)["status"]["type"] == "active"
        seen.update((message, ("pending" if busy else "unseen", None)) for message in missing)
    return seen


def direction_seen(client, worker, pending):
    return directions_seen(client, worker, [pending])[pending.get("clientUserMessageId", pending["id"])]


def refresh_directions(client, worker, except_id=None, include_unconfirmed=False):
    directions = pending_directions(worker)
    # Only explicit status can settle an unconfirmed send and report its verdict to the caller.
    observed = [entry for entry in directions if entry["id"] != except_id and not entry.get("neverArrived")
                and (include_unconfirmed or not entry.get("unconfirmed"))]
    seen = directions_seen(client, worker, observed)
    now = time.time()
    expired = [entry for entry in observed if seen[entry["clientUserMessageId"]][0] == "unseen"
               and now - entry.get("sentAt", 0) >= DIRECTION_LOST_AFTER_SECONDS]
    if expired:
        time.sleep(DIRECTION_RECHECK_SECONDS)
        for message, (state, submission) in directions_seen(client, worker, expired).items():
            seen[message] = ("lost" if state == "unseen" else state), submission

    pending = []
    for entry in directions:
        state, _ = seen.get(entry["clientUserMessageId"], (None, None))
        if state == "finished":
            continue
        if state == "lost" and not entry.get("unconfirmed"):
            print(f"Direction {entry['id']} is absent from the Codex queue and turn history.", file=sys.stderr)
            continue
        if state in {"queued", "running", "lost"} and entry.get("unconfirmed"):
            entry = entry.copy()
            del entry["unconfirmed"]
            if state == "lost":
                entry["neverArrived"] = True
        pending.append(entry)
    if pending != directions:
        worker["codexDirections"] = pending
    return seen


def save_worker(path, worker):
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".")
    try:
        with os.fdopen(descriptor, "w") as file:
            json.dump(worker, file)
            file.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def reconcile_directions(client, record, worker, except_id=None, report_unconfirmed=False):
    original = worker.copy()
    seen = refresh_directions(client, worker, except_id, include_unconfirmed=report_unconfirmed)
    if worker != original:
        save_worker(record, worker)
    if report_unconfirmed:
        verdicts = {"queued": "queued", "running": "ran", "finished": "ran", "lost": "never arrived"}
        for entry in original.get("codexDirections", []):
            if entry.get("neverArrived"):
                state = "lost"
            elif entry.get("unconfirmed"):
                state, _ = seen[entry["clientUserMessageId"]]
            else:
                continue
            print(f"Direction {entry['id']}: {verdicts.get(state, 'still unconfirmed')}.", file=sys.stderr)
    return seen


def resume_worker(client, thread):
    try:
        client.call("thread/resume", {"threadId": thread, "excludeTurns": True})
    except (OSError, ValueError, KeyError) as error:
        print(f"Direction was queued. Could not resume worker: {error}", file=sys.stderr)
        return False
    return True


def dispatch_queued_direction(client, worker, submission, status):
    thread = worker["id"]
    if status == "notLoaded" and not resume_worker(client, thread):
        return False
    try:
        queued = client.call("thread/queue/list", {"threadId": thread, "limit": QUEUE_PAGE_SIZE})["data"]
        if any(entry["id"] == submission for entry in queued):
            current = read_thread(client, worker)["status"]["type"]
            if current == "notLoaded":
                return resume_worker(client, thread)
            if current == "idle":
                # With no submission ID, Codex starts the head of the queue under its dispatch lock.
                client.call("thread/queue/start", {"threadId": thread})
    except (OSError, ValueError, KeyError) as error:
        print(f"Direction was queued. Could not start worker queue: {error}", file=sys.stderr)
        return False
    return True


def queue_direction(client, record, worker, text):
    info = read_thread(client, worker)
    directions = [entry for entry in pending_directions(worker) if not entry.get("neverArrived")]
    thread = worker["id"]
    turns = client.call("thread/turns/list", {
        "threadId": thread, "sortDirection": "desc", "limit": 1, "itemsView": "notLoaded",
    })["data"]
    token = str(uuid.uuid4())
    direction = {"id": token, "clientUserMessageId": token, "previousTurn": turns[0]["id"] if turns else None,
                 "sentAt": int(time.time()), "unconfirmed": True}
    directions.append(direction)
    worker["codexDirections"] = directions
    record_sent_direction(worker, token)
    save_worker(record, worker)
    try:
        submission = client.call("thread/queue/add", {
            "threadId": thread, "clientUserMessageId": token,
            "input": [{"type": "text", "text_elements": [], "text":
                       "Direction from your Anderton. Follow the existing approval policy.\n\n" + text}],
        })["queuedSubmission"]["id"]
    except (OSError, ValueError, KeyError) as error:
        # These errors reject the request before Codex writes the queue.
        if isinstance(error, RequestRejected) and error.code in {-32600, -32601, -32602}:
            directions.pop()
            save_worker(record, worker)
            raise
        print(f"Direction {token} is unconfirmed: {error}. Check worker status before resending.", file=sys.stderr)
        return DIRECTION_UNCONFIRMED_EXIT
    print(f"Queued message {submission} for thread {thread}.")
    ready = dispatch_queued_direction(client, worker, submission, info["status"]["type"])
    del direction["unconfirmed"]
    try:
        save_worker(record, worker)
        if ready:
            reconcile_directions(client, record, worker, except_id=token)
    except (OSError, ValueError, KeyError) as error:
        print(f"Direction was queued. Could not update direction tracking: {error}", file=sys.stderr)
    return int(not ready)


DIRECTION_PREFIX = "Direction from your Anderton. Follow the existing approval policy.\n\n"
# The Anderton's sent directions kept for retire.sh; the oldest go first past this many.
DIRECTION_LEDGER_SIZE = 500


def record_sent_direction(worker, client_id):
    ledger = worker.setdefault("codexDirectionLedger", {"since": int(time.time() * 1000), "ids": []})
    ledger["ids"] = [*ledger["ids"], client_id][-DIRECTION_LEDGER_SIZE:]


def inbound_since_report(client, worker, through_ms=None):
    """The user messages in the worker's thread since its last report that its Anderton did not send, oldest first:
    a completed turn whose final message is a report ends the scan. The Anderton's are its launch brief and the
    directions worker.sh recorded sending; one sent before the record kept that ledger is known by the text it adds."""
    if not worker.get("id"):
        raise ValueError("the record names no Codex thread")
    thread = worker["id"]
    read_thread(client, worker)
    ledger = worker.get("codexDirectionLedger") or {}
    sent = set(ledger.get("ids", [])) | {entry.get("clientUserMessageId", entry["id"]) for entry in pending_directions(worker)}
    ledger_since = ledger.get("since")
    marker = f"Anderton launch {uuid.UUID(worker['codexLaunchToken'])}" if worker.get("codexLaunchToken") else None
    held = []
    for turn in client.pages("thread/turns/list", threadId=thread, sortDirection="desc", limit=20, itemsView="notLoaded"):
        if turn["status"] == "completed" and final_report(client, thread, turn["id"]):
            break
        turn_end = (turn.get("completedAt") or turn.get("startedAt") or 0) * 1000 or None
        for entry in client.pages("thread/items/list", threadId=thread, turnId=turn["id"], limit=50):
            item = entry["item"]
            if item["type"] != "userMessage":
                continue
            text = "\n".join(part["text"] for part in item["content"] if part.get("type") == "text")
            # A time no later than the message's own, so a review through it covers the message.
            at = entry.get("completedAtMs") or entry.get("startedAtMs") or turn_end or int(time.time() * 1000)
            if item.get("clientId") in sent or (marker and text.partition("\n")[0] == marker):
                continue
            if (ledger_since is None or at < ledger_since) and text.startswith(DIRECTION_PREFIX):
                continue
            if through_ms is not None and at <= through_ms:
                continue
            line = next((part.strip() for part in text.splitlines() if part.strip()), "(no text)")[:200]
            held.append({"at": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(at / 1000)) + f".{at % 1000:03d}Z",
                         "from": "the user", "line": line})
    return sorted(held, key=lambda message: message["at"])


def deliver_notice(client, claim, notice):
    worker = claim_thread(claim)
    thread = worker["id"]
    info = read_thread(client, worker)
    receipt_path = notice / "receipt.json"
    if receipt_path.exists():
        receipt = json.loads(receipt_path.read_text())
        for look in range(2):
            state, submission = direction_seen(client, worker, receipt)
            if state == "finished":
                return True
            if state == "queued":
                status = read_thread(client, worker)["status"]["type"]
                if status == "notLoaded":
                    client.call("thread/resume", {"threadId": thread, "excludeTurns": True})
                elif status == "idle":
                    # A queue can remain stopped after an interruption or daemon restart.
                    client.call("thread/queue/start", {"threadId": thread, "queuedSubmissionId": submission["id"]})
                return False
            if state in {"pending", "running"} or time.time() - receipt["sentAt"] < DIRECTION_LOST_AFTER_SECONDS:
                return False
            if look == 0:
                time.sleep(DIRECTION_RECHECK_SECONDS)
    else:
        turns = client.call("thread/turns/list", {
            "threadId": thread, "limit": 1, "itemsView": "notLoaded",
        })["data"]
        receipt = {"id": str(uuid.uuid4()), "previousTurn": turns[0]["id"] if turns else None}
    receipt["sentAt"] = int(time.time())
    save_worker(receipt_path, receipt)
    client.call("thread/queue/add", {
        "threadId": thread, "clientUserMessageId": receipt["id"],
        "input": [{"type": "text", "text_elements": [], "text": (notice / "message").read_text()}],
    })
    if info["status"]["type"] == "notLoaded":
        client.call("thread/resume", {"threadId": thread, "excludeTurns": True})
    return False


def worker_bookmark(worker):
    thread = uuid.UUID(worker["id"])
    adoption = worker.get("codexAdoptionId")
    return f"codex-{thread}-{uuid.UUID(adoption)}.json" if adoption else f"codex-{thread}.json"


def blocker_flags(info):
    return sorted(set(info["status"].get("activeFlags", [])) & {"waitingOnApproval", "waitingOnUserInput"})


def blocker_key(client, thread, running, flags):
    # Successive approval requests can share a tool item ID in Codex.
    items = client.call("thread/items/list", {
        "threadId": thread, "turnId": running, "sortDirection": "desc", "limit": 1,
    })["data"] if running else []
    return [running, flags, items[0]["item"]["id"] if items else None]


def blocker_reasons(flags):
    return " and ".join("approval" if flag == "waitingOnApproval" else "user input" for flag in flags)


def blocker_signal(worker, key):
    label = f"=== {worker['name']} (Codex {worker['id']}, waiting on {blocker_reasons(key[1])})"
    return label + "\t" + json.dumps(key, separators=(",", ":"))


def blocker_during_notice(worker, pending_stage, bookmarks):
    thread = str(uuid.UUID(worker["id"]))
    with Codex(Path(worker["codexHome"])) as client:
        flags = blocker_flags(read_thread(client, worker))
        if not flags:
            return
        turns = client.call("thread/turns/list", {"threadId": thread, "limit": 1, "itemsView": "notLoaded"})["data"]
        running = turns[0]["id"] if turns and turns[0]["status"] == "inProgress" else None
        key = blocker_key(client, thread, running, flags)
    for directory in (pending_stage, bookmarks):
        bookmark = directory / worker_bookmark(worker)
        if not bookmark.is_file():
            continue
        block = json.loads(bookmark.read_text()).get("block") or {}
        if block.get("key") == key and time.time() - block["notifiedAt"] < BLOCK_REMINDER_SECONDS:
            return
    print(blocker_signal(worker, key))


def sweep_worker(worker, state_dir, stage_dir, limited=None):
    thread = str(uuid.UUID(worker["id"]))
    name = worker["name"]
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
        raise ValueError("Invalid worker name")
    bookmark = worker_bookmark(worker)
    previous = state_dir / bookmark
    state = json.loads(previous.read_text()) if previous.exists() else {"turn": worker.get("codexBaselineTurn")}
    events = []
    with Codex(Path(worker["codexHome"])) as client:
        info = read_thread(client, worker)
        waiting = blocker_flags(info)
        completed = []
        running = None
        latest = None
        for turn in client.pages("thread/turns/list", threadId=thread, limit=20,
                                 itemsView="notLoaded"):
            latest = latest or turn
            if turn["id"] == state.get("turn"):
                break
            if turn["status"] == "inProgress":
                if running is None:
                    running = turn["id"]
            else:
                completed.append(turn)
        block = None
        if waiting:
            key = blocker_key(client, thread, running, waiting)
            previous_block = state.get("block")
            now = int(time.time())
            same_block = isinstance(previous_block, dict) and previous_block["key"] == key
            if not same_block or now - previous_block["notifiedAt"] >= BLOCK_REMINDER_SECONDS:
                block = {"key": key, "notifiedAt": now}
                still = "still " if same_block else ""
                reported = os.environ.get("ANDERTON_REPORTED_BLOCKS")
                already_reported = reported and blocker_signal(worker, key) in Path(reported).read_text().splitlines()
                if same_block or not already_reported:
                    events.append(f"{name} (Codex {thread}) is {still}waiting on {blocker_reasons(waiting)}. Open its worker tab.")
            else:
                block = previous_block
        for turn in reversed(completed):
            if turn["status"] == "completed":
                text = final_report(client, thread, turn["id"])
                if text:
                    events.append(f"{name} (Codex {thread}) report:\n{text[:2000]}")
            elif usage_limit(turn) and failover_due(worker, turn["id"]):
                events.append(f"{name} (Codex {thread}) turn {turn['id']} failed at the usage limit of "
                              f"{worker['codexHome']}.")
            elif turn["status"] in {"failed", "interrupted"}:
                events.append(f"{name} (Codex {thread}) turn {turn['id']} {turn['status']}.")
        # Offered on every sweep while due, not only when first reported, so a move that could not run is retried.
        if (limited is not None and latest and latest["status"] != "inProgress" and usage_limit(latest)
                and failover_due(worker, latest["id"])):
            limited.append(worker)
        current = {"turn": completed[0]["id"] if completed else state.get("turn"), "block": block}
    if state != current:
        (stage_dir / bookmark).write_text(json.dumps(current) + "\n")
    return events


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    find = commands.add_parser("find")
    find.add_argument("home", type=Path)
    find.add_argument("directory", type=Path)
    endpoint = find.add_mutually_exclusive_group(required=True)
    endpoint.add_argument("--since", type=int)
    endpoint.add_argument("--after")
    find.add_argument("--token", required=True)
    launch = commands.add_parser("launch-matches")
    launch.add_argument("record", type=Path)
    launch.add_argument("thread")
    identity = commands.add_parser("identity")
    identity.add_argument("home", type=Path)
    identity.add_argument("thread")
    identity.add_argument("--adopt", action="store_true")
    claim_state = commands.add_parser("claim-state")
    claim_state.add_argument("claim", type=Path)
    notice = commands.add_parser("notice")
    notice.add_argument("claim", type=Path)
    notice.add_argument("notice", type=Path)
    blocker = commands.add_parser("blocker-during-notice")
    blocker.add_argument("record", type=Path)
    blocker.add_argument("pending_stage", type=Path)
    blocker.add_argument("bookmarks", type=Path)
    watch = commands.add_parser("start-watch")
    watch.add_argument("script", type=Path)
    watch.add_argument("claim", type=Path)
    unloaded = commands.add_parser("unloaded")
    unloaded.add_argument("record", type=Path)
    unloaded.add_argument("--wait", type=int, default=0)
    loaded = commands.add_parser("loaded")
    loaded.add_argument("home", type=Path)
    loaded.add_argument("thread")
    loaded.add_argument("--wait", type=int, default=0)
    limit = commands.add_parser("limited")
    limit.add_argument("record", type=Path)
    still = commands.add_parser("still-limited")
    still.add_argument("record", type=Path)
    still.add_argument("turn")
    resume = commands.add_parser("resume-on")
    resume.add_argument("record", type=Path)
    resume.add_argument("home", type=Path)
    inbound = commands.add_parser("inbound-since-report")
    inbound.add_argument("record", type=Path)
    inbound.add_argument("--reviewed-through")
    for command in ("state", "inactive", "output", "message"):
        action = commands.add_parser(command)
        action.add_argument("record", type=Path)
        if command == "message":
            action.add_argument("text")
        if command == "inactive":
            action.add_argument("--directions-only", action="store_true")
        if command in {"state", "inactive"}:
            action.add_argument("--prune", action="store_true", help="save reconciled directions under the worker lock")
    sweep = commands.add_parser("sweep")
    sweep.add_argument("records", nargs="+", type=Path)
    args = parser.parse_args()

    if args.command == "start-watch":
        # The Codex command runner ends its tool's process group after the command returns.
        subprocess.Popen([args.script, "--codex", args.claim], start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    elif args.command == "find":
        directory = args.directory.resolve()
        with Codex(args.home) as client:
            thread = find_thread(client, directory, args.after, args.token, args.since)
        if thread is None:
            return 3
        print(thread)
    elif args.command == "launch-matches":
        worker = json.loads(args.record.read_text())
        with Codex(Path(worker["codexHome"])) as client:
            thread = thread_identity(client, args.thread)
            if thread["dir"] != str(Path(worker["dir"]).resolve()):
                raise ValueError("Codex worker launch directory differs from the thread")
            marker = f"Anderton launch {uuid.UUID(worker['codexLaunchToken'])}"
            match = started_with(client, thread["id"], marker)
            if match is None:
                raise ValueError("The Codex thread's first user message is unavailable")
            return 0 if match else 3
    elif args.command == "identity":
        with Codex(args.home) as client:
            info = thread_identity(client, args.thread)
            if archived(client, info["id"]):
                raise ValueError("The Codex thread is archived")
            if args.adopt:
                completed = next((turn for turn in client.pages("thread/turns/list", threadId=info["id"],
                                  limit=10, itemsView="notLoaded") if turn["status"] != "inProgress"), None)
                info["baseline"] = completed["id"] if completed else None
            print(json.dumps(info))
    elif args.command in {"claim-state", "notice"}:
        claim = json.loads(args.claim.read_text())
        with Codex(Path(claim["codexHome"])) as client:
            worker = claim_thread(claim)
            if archived(client, worker["id"]):
                if args.command == "claim-state":
                    print("gone")
                    return 0
                raise ValueError("The Codex coordinator thread is archived")
            if args.command == "notice":
                return 0 if deliver_notice(client, claim, args.notice) else 3
            read_thread(client, worker)
            print("live")
    elif args.command in {"unloaded", "loaded"}:
        if args.command == "unloaded":
            worker = json.loads(args.record.read_text())
            home, thread = Path(worker["codexHome"]), worker["id"]
        else:
            home, thread = args.home, args.thread
        deadline = time.monotonic() + args.wait
        while True:
            try:
                with Codex(home) as client:
                    if (thread in client.pages("thread/loaded/list")) == (args.command == "loaded"):
                        return 0
            except OSError:
                if args.command == "unloaded":
                    raise
            if time.monotonic() >= deadline:
                return 3
            time.sleep(2)
    elif args.command == "limited":
        worker = json.loads(args.record.read_text())
        with Codex(Path(worker["codexHome"])) as client:
            message = limited_turn(client, worker)
        if message is None:
            return 3
        print(f"{message[0]}\n{message[1]}")
    elif args.command == "still-limited":
        # The limited turn is still the thread's latest and nothing is queued or running behind it.
        worker = json.loads(args.record.read_text())
        with Codex(Path(worker["codexHome"])) as client:
            turns = client.call("thread/turns/list", {"threadId": worker["id"], "limit": 1, "itemsView": "notLoaded"})["data"]
            if not turns or turns[0]["id"] != args.turn:
                return 3
            if client.call("thread/queue/list", {"threadId": worker["id"], "limit": 1})["data"]:
                return 3
            return 0 if read_thread(client, worker)["status"]["type"] in QUIET_AFTER_FAILURE else 3
    elif args.command == "inbound-since-report":
        through = None
        if args.reviewed_through:
            through = int(datetime.datetime.fromisoformat(args.reviewed_through.replace("Z", "+00:00")).timestamp() * 1000)
        worker = json.loads(args.record.read_text())
        with Codex(Path(worker["codexHome"])) as client:
            held = inbound_since_report(client, worker, through)
        print(json.dumps({"messages": held}))
        return 4 if held else 0
    elif args.command == "resume-on":
        resume_on(json.loads(args.record.read_text()), args.home)
    elif args.command == "blocker-during-notice":
        blocker_during_notice(json.loads(args.record.read_text()), args.pending_stage, args.bookmarks)
    elif args.command in {"state", "inactive", "output", "message"}:
        worker = json.loads(args.record.read_text())
        with Codex(Path(worker["codexHome"])) as client:
            if args.command == "message":
                return queue_direction(client, args.record, worker, args.text)
            if args.command == "inactive" and not worker["id"]:
                # retire.sh removes the worktree on this answer, so every thread in it is read, from the full listing:
                # Codex can run a turn whose thread has no index row, and its order is not creation order (it sorts
                # rollouts by local file time). A listing or read that fails keeps the worktree.
                quiet = {"idle", "notLoaded"}
                for thread in client.pages("thread/list", timeout=DIRECTORY_LIST_SECONDS, cwd=worker["dir"], limit=50):
                    listed = thread.get("status")
                    if isinstance(listed, dict) and listed.get("type") not in quiet:
                        return 1
                    # A listing can still say idle for a turn that has started; only a live read settles it.
                    live = client.call("thread/read", {"threadId": thread["id"], "includeTurns": False})["thread"]
                    if live["status"]["type"] not in quiet:
                        return 1
                return 0
            info = read_thread(client, worker)
            if args.command == "inactive":
                if args.prune:
                    reconcile_directions(client, args.record, worker)
                return int(not is_inactive(client, worker, directions_only=args.directions_only,
                                           reconcile=not args.prune))
            if args.command == "state" and args.prune:
                seen = reconcile_directions(client, args.record, worker, report_unconfirmed=True)
                if (info["status"]["type"] == "notLoaded" and any(state == "queued" for state, _ in seen.values())
                        and not resume_worker(client, worker["id"])):
                    return 1
            if args.command == "output":
                thread = worker["id"]
                turns = client.call("thread/turns/list", {
                    "threadId": thread, "limit": 1, "itemsView": "notLoaded",
                })["data"]
                print(f"Codex thread {thread} is {info['status']['type']}.")
                if turns:
                    entries = client.call("thread/items/list", {
                        "threadId": thread, "turnId": turns[0]["id"],
                        "sortDirection": "desc", "limit": 16,
                    })["data"]
                    for entry in reversed(entries):
                        item = entry["item"]
                        if item["type"] == "agentMessage" and item.get("text"):
                            print(item["text"][:2000])
                return 0
        if args.command == "state":
            print(json.dumps(info["status"]))
    else:
        state_dir = Path(os.environ["ANDERTON_PROBE_STATE"])
        stage_dir = Path(os.environ["ANDERTON_PROBE_STAGE"])
        limited_out = os.environ.get("ANDERTON_CODEX_LIMITED")
        failed = False
        for path in args.records:
            try:
                worker = json.loads(path.read_text())
                limited = []
                for event in sweep_worker(worker, state_dir, stage_dir, limited):
                    print(event)
                if limited and limited_out:
                    with open(limited_out, "a") as file:
                        file.write(f"{path}\t{worker['id']}\n")
            except (OSError, ValueError, KeyError) as error:
                print(f"{path.stem}: {error}", file=sys.stderr)
                failed = True
        return int(failed)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError) as error:
        print(f"Codex worker: {error}", file=sys.stderr)
        sys.exit(1)
