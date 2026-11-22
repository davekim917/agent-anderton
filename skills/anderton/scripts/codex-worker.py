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
import sys
import tempfile
import time
import uuid

MAX_MESSAGE = 16 * 1024 * 1024
BLOCK_REMINDER_SECONDS = 300
# Longer than any request a lost connection can leave in flight: Codex.call waits 5 seconds for its answer.
DIRECTION_LOST_AFTER_SECONDS = 60
# Codex deletes a queue entry only once its turn has started; a second look this much later sees that turn.
DIRECTION_RECHECK_SECONDS = 3
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
        self.socket.settimeout(5)
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

    def call(self, method, params):
        self.request_id += 1
        request = self.request_id
        self.send({"id": request, "method": method, "params": params})
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            self.socket.settimeout(max(0.001, deadline - time.monotonic()))
            message = self.receive()
            if message.get("id") == request and "method" not in message:
                self.socket.settimeout(5)
                if "error" in message:
                    raise RequestRejected(method, message["error"])
                return message["result"]
        raise ValueError(f"Timed out waiting for {method}")

    def pages(self, method, **params):
        seen = set()
        while True:
            result = self.call(method, params)
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


def has_message(client, thread, turn, marker, first_only=False):
    for entry in client.pages("thread/items/list", threadId=thread, turnId=turn, limit=10):
        item = entry["item"]
        if item["type"] != "userMessage":
            continue
        if any(part["type"] == "text" and part["text"].partition("\n")[0] == marker
               for part in item["content"]):
            return True
        if first_only:
            return False
    return False


def started_with(client, thread, marker):
    turns = client.call("thread/turns/list", {
        "threadId": thread, "sortDirection": "asc", "limit": 1, "itemsView": "notLoaded",
    })["data"]
    return bool(turns and has_message(client, thread, turns[0]["id"], marker, first_only=True))


def find_thread(client, directory, after, token):
    marker = f"Anderton launch {uuid.UUID(token)}"
    match = None
    for thread in client.pages("thread/list", cwd=str(directory), limit=10):
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


def is_inactive(client, worker):
    if client.call("thread/queue/list", {"threadId": worker["id"], "limit": 1})["data"]:
        return False
    if direction_state(client, worker) == "pending":
        return False
    return read_thread(client, worker)["status"]["type"] in {"idle", "notLoaded"}


def direction_state(client, worker):
    """The last direction's outcome: none, finished, pending, or lost when its send never reached Codex."""
    pending = worker.get("codexDirection")
    if not pending:
        return "none"
    for look in range(2):
        if look:
            time.sleep(DIRECTION_RECHECK_SECONDS)
        state = direction_seen(client, worker, pending)
        if state != "unseen":
            return state
    # Neither queued nor in a turn since the one before it, twice, with no turn running. A connection that failed
    # mid-send can leave the request in flight briefly; after that it never arrived. A marker from before sentAt was
    # recorded is long past that.
    if time.time() - pending.get("sentAt", 0) < DIRECTION_LOST_AFTER_SECONDS:
        return "pending"
    return "lost"


def direction_seen(client, worker, pending):
    """finished or pending as Codex shows the direction, pending while any turn runs, else unseen."""
    thread = worker["id"]
    # The queue, then the status, then the turns: an entry leaves the queue only once its turn has started, and that
    # turn records the direction before it can end, so a direction cannot pass all three reads unseen.
    for entry in client.pages("thread/queue/list", threadId=thread, limit=20):
        if entry.get("clientUserMessageId") == pending["id"]:
            return "pending"
    if read_thread(client, worker)["status"]["type"] == "active":
        return "pending"
    for turn in client.pages("thread/turns/list", threadId=thread, limit=20, itemsView="notLoaded"):
        if turn["status"] == "inProgress":
            return "pending"
        for entry in client.pages("thread/items/list", threadId=thread, turnId=turn["id"], limit=10):
            item = entry["item"]
            if item["type"] == "userMessage" and item.get("clientId") == pending["id"]:
                return "finished" if turn["status"] in {"completed", "interrupted", "failed"} else "pending"
        if turn["id"] == pending["previousTurn"]:
            break
    return "unseen"


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


def queue_direction(client, record, worker, text):
    info = read_thread(client, worker)
    state = direction_state(client, worker)
    if state == "pending":
        raise ValueError("Wait for the preceding Anderton direction to finish")
    if state == "lost":
        print("The preceding Anderton direction never reached Codex; it is replaced by this one.", file=sys.stderr)
    thread = worker["id"]
    turns = client.call("thread/turns/list", {
        "threadId": thread, "limit": 1, "itemsView": "notLoaded",
    })["data"]
    token = str(uuid.uuid4())
    worker["codexDirection"] = {"id": token, "previousTurn": turns[0]["id"] if turns else None,
                                "sentAt": int(time.time())}
    save_worker(record, worker)
    try:
        submitted = client.call("thread/queue/add", {
            "threadId": thread, "clientUserMessageId": token,
            "input": [{"type": "text", "text_elements": [], "text":
                       "Direction from your Claude Code Anderton. Follow the existing approval policy.\n\n" + text}],
        })["queuedSubmission"]
    except RequestRejected as error:
        # Protocol and request validation errors are returned before the queue is written.
        if error.code in {-32600, -32601, -32602}:
            del worker["codexDirection"]
            save_worker(record, worker)
        raise
    print(f"Queued message {submitted['id']} for thread {thread}.")
    if info["status"]["type"] == "notLoaded":
        try:
            client.call("thread/resume", {"threadId": thread, "excludeTurns": True})
        except (OSError, ValueError) as error:
            print(f"Direction was queued. Could not resume worker: {error}", file=sys.stderr)


def sweep_worker(worker, state_dir, stage_dir):
    thread = str(uuid.UUID(worker["id"]))
    name = worker["name"]
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
        raise ValueError("Invalid worker name")
    bookmark = f"codex-{thread}.json"
    previous = state_dir / bookmark
    state = json.loads(previous.read_text()) if previous.exists() else {}
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
    endpoint = find.add_mutually_exclusive_group()
    endpoint.add_argument("--baseline", action="store_true")
    endpoint.add_argument("--after")
    find.add_argument("--token")
    for command in ("state", "inactive", "output", "message"):
        action = commands.add_parser(command)
        action.add_argument("record", type=Path)
        if command == "message":
            action.add_argument("text")
    sweep = commands.add_parser("sweep")
    sweep.add_argument("records", nargs="+", type=Path)
    args = parser.parse_args()

    if args.command == "find":
        directory = args.directory.resolve()
        with Codex(args.home) as client:
            if args.baseline:
                threads = client.call("thread/list", {"cwd": str(directory), "limit": 1})["data"]
                if threads:
                    print(uuid.UUID(threads[0]["id"]))
                return 0
            if not args.token:
                raise ValueError("Codex worker registration requires its launch token")
            thread = find_thread(client, directory, args.after, args.token)
        if thread is None:
            return 3
        print(thread)
    elif args.command in {"state", "inactive", "output", "message"}:
        worker = json.loads(args.record.read_text())
        with Codex(Path(worker["codexHome"])) as client:
            if args.command == "message":
                queue_direction(client, args.record, worker, args.text)
                return 0
            if args.command == "inactive" and not worker["id"]:
                result = client.call("thread/list", {"cwd": worker["dir"], "limit": 1})
                threads = result["data"]
                return int(bool(threads and threads[0]["id"] != worker.get("codexBaseline")))
            if args.command == "inactive":
                return int(not is_inactive(client, worker))
            info = read_thread(client, worker)
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
