#!/usr/bin/env python3
"""Read Codex workers through the local daemon's WebSocket JSON-RPC endpoint."""

import argparse
import base64
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
# Codex 0.171 caps the queue at 100 entries. Read them in one page to avoid shifts while it dispatches.
QUEUE_PAGE_SIZE = 100
# RFC 6455 requires the handshake GUID in uppercase ASCII.
HANDSHAKE_GUID = str(uuid.UUID("258eafa5-e914-47da-95ca-c5ab0dc85b11")).upper().encode("ascii")
REPORT = re.compile(r"^(RESULT|QUESTION|BLOCKED|ANSWER):[ \t]*\S")


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


def is_inactive(client, worker, directions_only=False, reconcile=True):
    if reconcile:
        refresh_directions(client, worker)
    if pending_directions(worker):
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


def refresh_directions(client, worker, except_id=None):
    directions = pending_directions(worker)
    observed = [entry for entry in directions if entry["id"] != except_id]
    seen = directions_seen(client, worker, observed)
    now = time.time()
    expired = [entry for entry in observed if seen[entry["clientUserMessageId"]][0] == "unseen"
               and (entry.get("deleteUnconfirmed") or now - entry.get("sentAt", 0) >= DIRECTION_LOST_AFTER_SECONDS)]
    if expired:
        time.sleep(DIRECTION_RECHECK_SECONDS)
        rechecked = directions_seen(client, worker, expired)
        for entry in expired:
            message = entry["clientUserMessageId"]
            state, submission = rechecked[message]
            if state == "unseen":
                state = "deleted" if entry.get("deleteUnconfirmed") else "lost"
            seen[message] = state, submission

    pending = []
    for entry in directions:
        state, _ = seen.get(entry["clientUserMessageId"], (None, None))
        if state == "lost":
            print(f"Direction {entry['id']} is absent from the Codex queue and turn history.", file=sys.stderr)
        if state in {"lost", "deleted"} or (state == "finished" and not entry.get("replaces")):
            continue
        if state in {"queued", "running", "finished"} and entry.get("unconfirmed"):
            entry = confirmed_direction(entry)
        if state == "running" and entry.get("deleteUnconfirmed"):
            entry = {key: value for key, value in entry.items() if key != "deleteUnconfirmed"}
        pending.append(entry)
    if pending != directions:
        worker["codexDirections"] = pending
    return seen


def confirmed_direction(entry):
    fields = {"unconfirmed"} if entry.get("replaces") else {"unconfirmed", "textHash"}
    return {key: value for key, value in entry.items() if key not in fields}


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


def finish_replacements(client, record, worker, finished=()):
    directions = pending_directions(worker)
    replacements = [entry for entry in reversed(directions) if entry.get("replaces") and not entry.get("unconfirmed")]
    if not replacements:
        return
    thread = worker["id"]
    queued = {entry["clientUserMessageId"]: entry["id"]
              for entry in client.pages("thread/queue/list", threadId=thread, limit=QUEUE_PAGE_SIZE)}
    for replacement in replacements:
        if replacement not in directions:
            continue
        targets = set(replacement["replaces"])
        for direction in directions[:]:
            message = direction["clientUserMessageId"]
            if message not in targets or message not in queued:
                continue
            # The process can lose the reply after the queue changes. Keep the target until the next observation.
            direction["deleteUnconfirmed"] = True
            save_worker(record, worker)
            result = client.call("thread/queue/delete", {"threadId": thread, "queuedSubmissionId": queued.pop(message)})
            if result["deleted"]:
                directions.remove(direction)
            else:
                direction.pop("deleteUnconfirmed", None)
            save_worker(record, worker)
        if any(entry.get("deleteUnconfirmed") and entry["clientUserMessageId"] in targets for entry in directions):
            continue
        if replacement["clientUserMessageId"] in finished:
            directions.remove(replacement)
        else:
            replacement.pop("replaces")
            replacement.pop("textHash")
        save_worker(record, worker)


def reconcile_directions(client, record, worker, info, new_id=None):
    if new_id is not None:
        finish_replacements(client, record, worker)
    original = worker.copy()
    seen = refresh_directions(client, worker, except_id=new_id)
    if worker != original:
        save_worker(record, worker)
    for entry in original.get("codexDirections", []):
        state, _ = seen.get(entry["clientUserMessageId"], (None, None))
        if entry.get("unconfirmed") and state in {"queued", "running", "finished"}:
            print(f"Direction {entry['id']} confirmed by Codex.", file=sys.stderr)
    finished = {message for message, (state, _) in seen.items() if state == "finished"}
    finish_replacements(client, record, worker, finished)
    if info["status"]["type"] == "notLoaded" and (new_id is not None or any(
            seen.get(entry["clientUserMessageId"], (None, None))[0] == "queued"
            for entry in pending_directions(worker))):
        resume_worker(client, worker["id"])
    return seen


def resume_worker(client, thread):
    try:
        client.call("thread/resume", {"threadId": thread, "excludeTurns": True})
    except (OSError, ValueError) as error:
        print(f"Direction was queued. Could not resume worker: {error}", file=sys.stderr)


def queue_direction(client, record, worker, text, replace=False):
    info = read_thread(client, worker)
    directions = pending_directions(worker)
    thread = worker["id"]
    text_hash = hashlib.sha256(text.encode()).hexdigest()
    retry = next((entry for entry in reversed(directions) if entry.get("textHash") == text_hash), None)
    if retry is not None:
        try:
            seen = reconcile_directions(client, record, worker, info)
        except (OSError, ValueError, KeyError) as error:
            print(f"Direction {retry['id']} reconciliation is unconfirmed: {error}", file=sys.stderr)
            return
        state, _ = seen[retry["clientUserMessageId"]]
        if state not in {"lost", "deleted"}:
            if not retry.get("unconfirmed"):
                print(f"Direction {retry['id']} was already submitted.", file=sys.stderr)
            elif state not in {"queued", "running", "finished"}:
                print(f"Direction {retry['id']} is still unconfirmed.", file=sys.stderr)
            return
        directions = pending_directions(worker)

    turns = client.call("thread/turns/list", {
        "threadId": thread, "sortDirection": "desc", "limit": 1, "itemsView": "notLoaded",
    })["data"]
    token = str(uuid.uuid4())
    direction = {"id": token, "clientUserMessageId": token, "previousTurn": turns[0]["id"] if turns else None,
                 "sentAt": int(time.time()), "unconfirmed": True, "textHash": text_hash}
    if replace and directions:
        direction["replaces"] = [entry["clientUserMessageId"] for entry in directions]
    directions.append(direction)
    worker["codexDirections"] = directions
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
        print(f"Direction {token} is unconfirmed: {error}", file=sys.stderr)
        return
    directions[-1] = confirmed_direction(direction)
    save_worker(record, worker)
    print(f"Queued message {submission} for thread {thread}.")
    try:
        reconcile_directions(client, record, worker, info, new_id=token)
    except (OSError, ValueError, KeyError) as error:
        print(f"Direction was queued. Queue reconciliation is unconfirmed: {error}", file=sys.stderr)


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


def sweep_worker(worker, state_dir, stage_dir):
    thread = str(uuid.UUID(worker["id"]))
    name = worker["name"]
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
        raise ValueError("Invalid worker name")
    bookmark = f"codex-{thread}.json"
    previous = state_dir / bookmark
    state = json.loads(previous.read_text()) if previous.exists() else {"turn": worker.get("codexBaselineTurn")}
    events = []
    with Codex(Path(worker["codexHome"])) as client:
        info = read_thread(client, worker)
        flags = info["status"].get("activeFlags", [])
        waiting = sorted(set(flags) & {"waitingOnApproval", "waitingOnUserInput"})
        completed = []
        running = None
        for turn in client.pages("thread/turns/list", threadId=thread, limit=20,
                                 itemsView="notLoaded"):
            if turn["id"] == state.get("turn"):
                break
            if turn["status"] == "inProgress":
                if running is None:
                    running = turn["id"]
            else:
                completed.append(turn)
        block = None
        if waiting:
            # Successive approval requests can share a tool item ID in Codex.
            items = client.call("thread/items/list", {
                "threadId": thread, "turnId": running, "sortDirection": "desc", "limit": 1,
            })["data"] if running else []
            key = [running, waiting, items[0]["item"]["id"] if items else None]
            previous_block = state.get("block")
            now = int(time.time())
            same_block = isinstance(previous_block, dict) and previous_block["key"] == key
            if not same_block or now - previous_block["notifiedAt"] >= BLOCK_REMINDER_SECONDS:
                block = {"key": key, "notifiedAt": now}
                reasons = ["approval" if flag == "waitingOnApproval" else "user input" for flag in waiting]
                still = "still " if same_block else ""
                events.append(f"{name} (Codex {thread}) is {still}waiting on {' and '.join(reasons)}. Open its worker tab.")
            else:
                block = previous_block
        for turn in reversed(completed):
            if turn["status"] == "completed":
                text = final_report(client, thread, turn["id"])
                if text:
                    events.append(f"{name} (Codex {thread}) report:\n{text[:2000]}")
            elif turn["status"] in {"failed", "interrupted"}:
                events.append(f"{name} (Codex {thread}) turn {turn['id']} {turn['status']}.")
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
    watch = commands.add_parser("start-watch")
    watch.add_argument("script", type=Path)
    watch.add_argument("claim", type=Path)
    for command in ("state", "inactive", "output", "message"):
        action = commands.add_parser(command)
        action.add_argument("record", type=Path)
        if command == "message":
            action.add_argument("--replace", action="store_true",
                                help="replace queued Anderton directions; a running turn is untouched")
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
    elif args.command in {"state", "inactive", "output", "message"}:
        worker = json.loads(args.record.read_text())
        with Codex(Path(worker["codexHome"])) as client:
            if args.command == "message":
                queue_direction(client, args.record, worker, args.text, replace=args.replace)
                return 0
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
            if args.command in {"inactive", "state"} and args.prune:
                reconcile_directions(client, args.record, worker, info)
            if args.command == "inactive":
                return int(not is_inactive(client, worker, directions_only=args.directions_only,
                                           reconcile=not args.prune))
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
        failed = False
        for path in args.records:
            try:
                worker = json.loads(path.read_text())
                for event in sweep_worker(worker, state_dir, stage_dir):
                    print(event)
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
