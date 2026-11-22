import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


path = Path(__file__).resolve().parents[1] / "skills/anderton/scripts/codex-worker.py"
spec = importlib.util.spec_from_file_location("codex_worker", path)
worker_api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker_api)


class FakeCodex:
    def __init__(self, worker):
        self.info = {"id": worker["id"], "cwd": worker["dir"], "status": {"type": "idle"}}
        self.turns = []
        self.items = {}
        self.threads = [self.info]
        self.latest = []
        self.queue = []
        self.checked_queue = False
        self.listings = []
        self.listed = []
        self.others = {}

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def call(self, method, params, timeout=None):
        if method == "thread/turns/list":
            return {"data": [{"id": params["threadId"]}]}
        if method == "thread/items/list":
            return {"data": self.latest}
        if method == "thread/queue/list":
            self.checked_queue = True
            return {"data": self.queue}
        assert method == "thread/read"
        if params["threadId"] in self.others:
            return {"thread": self.others[params["threadId"]]}
        assert params["threadId"] == self.info["id"]
        return {"thread": self.info}

    def pages(self, method, timeout=None, **params):
        if method == "thread/list":
            self.listings.append({**params, "timeout": timeout})
            threads = [thread for thread in self.threads if params.get("cwd", thread["cwd"]) == thread["cwd"]]
            return (self.listed.append(thread["id"]) or thread for thread in threads)
        if method == "thread/turns/list":
            return iter(self.turns)
        if method == "thread/queue/list":
            return iter(self.queue)
        assert method == "thread/items/list"
        return iter(self.items[params["turnId"]])


def message(text, phase="final_answer"):
    return {"item": {"type": "agentMessage", "text": text, "phase": phase}}


def user_message(text):
    return {"item": {"type": "userMessage", "content": [{"type": "text", "text": text}]}}


class WorkerTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        directory = Path(temporary.name).resolve()
        self.state = directory / "state"
        self.stage = directory / "stage"
        self.state.mkdir()
        self.stage.mkdir()
        self.record = directory / "worker.json"
        self.worker = {"id": "00000000-0000-7000-8000-000000000123", "name": "fixture",
                       "dir": str(directory / "worktree"), "codexHome": str(directory / "codex")}
        self.client = FakeCodex(self.worker)
        mock_client = patch.object(worker_api, "Codex", return_value=self.client)
        mock_client.start()
        self.addCleanup(mock_client.stop)

    def scan(self):
        return worker_api.sweep_worker(self.worker, self.state, self.stage)

    def delivered(self):
        for path in self.stage.iterdir():
            path.replace(self.state / path.name)

    def test_delivers_completed_turns_in_order_and_bookmarks_after_delivery(self):
        self.client.turns = [{"id": "third", "status": "inProgress"},
                             {"id": "second", "status": "completed"},
                             {"id": "first", "status": "completed"}]
        self.client.items = {"first": [message("RESULT: one")],
                             "second": [message("ANSWER: two"), message("RESULT: draft", "commentary")]}
        events = self.scan()
        self.assertEqual([event.splitlines()[-1] for event in events], ["RESULT: one", "ANSWER: two"])
        self.assertEqual(events, self.scan())
        self.delivered()
        self.assertEqual([], self.scan())
        self.client.turns[0]["status"] = "completed"
        self.client.items["third"] = [message("Done", None), message("RESULT: earlier", None)]
        self.assertEqual([], self.scan())

    def test_reports_new_blockers_only(self):
        self.client.turns = [{"id": "first", "status": "inProgress"}]
        self.client.info["status"] = {"type": "active", "activeFlags": ["waitingOnApproval"]}
        self.client.latest = [{"item": {"id": "approval-one"}}]
        self.assertIn("waiting on approval", self.scan()[0])
        self.delivered()
        self.assertEqual([], self.scan())
        self.client.latest = [{"item": {"id": "approval-two"}}]
        self.assertIn("waiting on approval", self.scan()[0])
        self.delivered()
        self.client.info["status"] = {"type": "active", "activeFlags": []}
        self.assertEqual([], self.scan())
        self.delivered()
        self.client.info["status"] = {"type": "active", "activeFlags": ["waitingOnUserInput"]}
        self.assertIn("waiting on user input", self.scan()[0])

    def test_rejects_mismatched_thread_worktree(self):
        self.client.info["cwd"] = str(self.state)
        with self.assertRaisesRegex(ValueError, "identity does not match"):
            self.scan()
        self.assertEqual([], list(self.stage.iterdir()))

    def test_reports_interrupted_turn_without_an_assistant_message(self):
        self.client.turns = [{"id": "first", "status": "interrupted"}]
        self.assertIn("interrupted", self.scan()[0])
        self.delivered()
        self.assertEqual([], self.scan())

    def test_launch_uses_first_user_message_of_the_matching_thread(self):
        expected = self.worker["id"]
        unrelated = "00000000-0000-7000-8000-000000000456"
        token = "00000000-0000-4000-8000-000000000789"
        marker = f"Anderton launch {token}"
        directory = Path(self.worker["dir"])
        self.client.threads = [{**self.client.info, "id": unrelated}, self.client.info]
        self.client.items[unrelated] = [user_message("Unrelated work"), user_message(marker)]
        self.client.items[expected] = [user_message(f"{marker}\n\nBrief")]
        self.assertEqual(expected, str(worker_api.find_thread(self.client, directory, "", token)))
        self.client.items[unrelated] = [user_message(marker)]
        with self.assertRaisesRegex(ValueError, "More than one"):
            worker_api.find_thread(self.client, directory, "", token)

    def test_launch_match_is_inconclusive_until_first_user_message_is_visible(self):
        thread = self.worker["id"]
        token = "00000000-0000-4000-8000-000000000789"
        directory = Path(self.worker["dir"])
        directory.mkdir()
        self.record.write_text(json.dumps({**self.worker, "codexLaunchToken": token}))
        with patch.object(worker_api.sys, "argv", ["codex-worker.py", "launch-matches", str(self.record), thread]):
            original = self.client.call
            with patch.object(self.client, "call", side_effect=lambda method, params:
                              {"data": []} if method == "thread/turns/list" else original(method, params)):
                with self.assertRaisesRegex(ValueError, "first user message is unavailable"):
                    worker_api.main()
                self.assertIsNone(worker_api.find_thread(self.client, directory, "", token))
            self.client.items[thread] = [message("Waiting for the brief")]
            with self.assertRaisesRegex(ValueError, "first user message is unavailable"):
                worker_api.main()
            self.assertIsNone(worker_api.find_thread(self.client, directory, "", token))
            self.client.items[thread] = [user_message("Unrelated work")]
            self.assertEqual(3, worker_api.main())
            self.assertIsNone(worker_api.find_thread(self.client, directory, "", token))
            self.client.items[thread] = [user_message(f"Anderton launch {token}\n\nBrief")]
            self.assertEqual(0, worker_api.main())
            self.assertEqual(thread, str(worker_api.find_thread(self.client, directory, "", token)))

    def test_a_launch_is_found_among_threads_created_since_it_without_a_cwd_filter(self):
        token = "00000000-0000-4000-8000-000000000789"
        marker = f"Anderton launch {token}"
        directory = Path(self.worker["dir"])
        launched = 1000
        elsewhere = {"id": "00000000-0000-7000-8000-000000000a01", "cwd": str(self.state), "createdAt": 1003}
        # The host clock stepped back after the launch time was recorded.
        launch = {**self.client.info, "createdAt": 1000 - 240}
        earlier = {"id": "00000000-0000-7000-8000-000000000a02", "cwd": self.worker["dir"], "createdAt": 1000 - 301}
        older = {"id": "00000000-0000-7000-8000-000000000a03", "cwd": self.worker["dir"], "createdAt": 600}
        self.client.threads = [elsewhere, launch, earlier, older]
        self.client.items[launch["id"]] = [user_message(f"{marker}\n\nBrief")]
        # An earlier worker in the same worktree path carrying the marker would be a second match if it were read.
        self.client.items[earlier["id"]] = [user_message(marker)]
        self.assertEqual(launch["id"], str(worker_api.find_thread(self.client, directory, None, token, launched)))
        self.assertNotIn("cwd", self.client.listings[-1])
        self.assertEqual("desc", self.client.listings[-1]["sortDirection"])
        self.assertIs(True, self.client.listings[-1]["useStateDbOnly"])
        self.assertEqual([elsewhere["id"], launch["id"], earlier["id"]], self.client.listed)

    def test_an_unregistered_worker_is_inactive_only_while_no_thread_in_its_worktree_runs(self):
        self.worker.update(id="", codexLaunchedAt=1000)
        self.record.write_text(json.dumps(self.worker))
        older = {"id": "00000000-0000-7000-8000-000000000a02", "cwd": self.worker["dir"], "createdAt": 600,
                 "status": {"type": "notLoaded"}}
        self.client.others[older["id"]] = {**older}
        elsewhere = {"id": "00000000-0000-7000-8000-000000000a01", "cwd": str(self.state), "createdAt": 1001,
                     "status": {"type": "active", "activeFlags": []}}
        launch = {**self.client.info, "createdAt": 1001, "status": {"type": "idle"}}
        # Codex orders this listing by local rollout file time, which a clock change can put out of creation order.
        self.client.threads = [older, elsewhere, launch]

        def inactive():
            with patch.object(worker_api.sys, "argv", ["codex-worker.py", "inactive", str(self.record)]):
                return worker_api.main()

        self.assertEqual(0, inactive())
        # The listing can still say idle for a turn that has started; the live read decides.
        self.client.info["status"] = {"type": "active", "activeFlags": []}
        self.assertEqual(1, inactive())
        self.client.info["status"] = {"type": "idle"}
        self.client.others[older["id"]]["status"] = {"type": "active", "activeFlags": []}
        self.assertEqual(1, inactive())
        self.client.others[older["id"]]["status"] = {"type": "notLoaded"}
        launch["status"] = {"type": "active", "activeFlags": ["waitingOnApproval"]}
        self.assertEqual(1, inactive())
        launch["status"] = {"type": "systemError"}
        self.assertEqual(1, inactive())
        del launch["status"]
        self.assertEqual(0, inactive())
        self.client.info["status"] = {"type": "systemError"}
        self.assertEqual(1, inactive())
        # Retirement removes the worktree on this answer: the full listing, which sees a thread the index lacks.
        for params in self.client.listings:
            self.assertEqual(self.worker["dir"], params["cwd"])
            self.assertNotIn("useStateDbOnly", params)
            self.assertEqual(worker_api.DIRECTORY_LIST_SECONDS, params["timeout"])

    def test_an_unregistered_worker_is_not_inactive_when_its_listing_fails(self):
        self.worker.update(id="", codexLaunchedAt=1000)
        self.record.write_text(json.dumps(self.worker))
        with patch.object(worker_api.sys, "argv", ["codex-worker.py", "inactive", str(self.record)]), \
                patch.object(self.client, "pages", side_effect=TimeoutError("timed out")), \
                self.assertRaises(TimeoutError):
            worker_api.main()

    def test_inactivity_requires_empty_queue_and_current_idle_status(self):
        self.assertTrue(worker_api.is_inactive(self.client, self.worker))
        self.client.queue = [{"id": "next"}]
        self.assertFalse(worker_api.is_inactive(self.client, self.worker))
        self.client.queue = []
        self.client.checked_queue = False
        original = self.client.call

        def starts_between_queue_and_status(method, params):
            if method == "thread/read" and self.client.checked_queue:
                self.client.info["status"] = {"type": "active"}
            return original(method, params)

        with patch.object(self.client, "call", side_effect=starts_between_queue_and_status):
            self.assertFalse(worker_api.is_inactive(self.client, self.worker))

    def test_waits_for_the_matching_direction_to_complete(self):
        self.worker["codexDirection"] = {"id": "direction-id", "previousTurn": "previous"}
        self.client.turns = [{"id": "new", "status": "inProgress"}]
        self.client.items["new"] = [user_message("Direction")]
        self.client.items["new"][0]["item"]["clientId"] = "direction-id"
        self.assertFalse(worker_api.is_inactive(self.client, self.worker))
        self.client.turns[0]["status"] = "completed"
        self.assertTrue(worker_api.is_inactive(self.client, self.worker))

    def test_clears_only_a_definitive_rejection(self):
        original = self.client.call
        rejected = worker_api.RequestRejected("thread/queue/add", {"code": -32600, "message": "invalid request"})

        for error in (rejected, TimeoutError("connection lost")):
            def reject_add(method, params):
                if method == "thread/queue/add":
                    self.assertIn("codexDirection", json.loads(self.record.read_text()))
                    raise error
                return original(method, params)

            with patch.object(self.client, "call", side_effect=reject_add), self.assertRaises(type(error)):
                worker_api.queue_direction(self.client, self.record, self.worker, "Direction")
            self.assertEqual(isinstance(error, TimeoutError), "codexDirection" in json.loads(self.record.read_text()))

    def test_replaces_a_direction_that_never_reached_codex_once_its_send_is_over(self):
        self.worker["codexDirection"] = {"id": "lost-id", "previousTurn": "previous", "sentAt": 1000}
        self.client.turns = [{"id": "previous", "status": "completed"}]
        self.client.items["previous"] = [user_message("Earlier work")]
        original = self.client.call
        added = []

        def accept_add(method, params):
            if method == "thread/queue/add":
                added.append(params["clientUserMessageId"])
                return {"queuedSubmission": {"id": "submission"}}
            return original(method, params)

        with patch.object(self.client, "call", side_effect=accept_add), patch.object(worker_api.time, "sleep"):
            with patch.object(worker_api.time, "time", return_value=1005):
                self.assertFalse(worker_api.is_inactive(self.client, self.worker))
            later = 1000 + worker_api.DIRECTION_LOST_AFTER_SECONDS
            with patch.object(worker_api.time, "time", return_value=later):
                self.client.queue = [{"id": "submission", "clientUserMessageId": "lost-id"}]
                with self.assertRaisesRegex(ValueError, "Wait for the preceding"):
                    worker_api.queue_direction(self.client, self.record, self.worker, "Next")
                self.client.queue = []
                self.assertTrue(worker_api.is_inactive(self.client, self.worker))
                worker_api.queue_direction(self.client, self.record, self.worker, "Next")
        saved = json.loads(self.record.read_text())["codexDirection"]
        self.assertEqual([saved["id"]], added)
        self.assertNotEqual("lost-id", saved["id"])

    def test_a_direction_whose_turn_is_starting_is_not_lost(self):
        self.worker["codexDirection"] = {"id": "starting-id", "previousTurn": "previous", "sentAt": 1000}
        self.client.turns = [{"id": "previous", "status": "completed"}]
        self.client.items["previous"] = [user_message("Earlier work")]
        later = 1000 + worker_api.DIRECTION_LOST_AFTER_SECONDS

        def turn_recorded(_seconds):
            self.client.turns.insert(0, {"id": "started", "status": "completed"})
            self.client.items["started"] = [user_message("Direction")]
            self.client.items["started"][0]["item"]["clientId"] = "starting-id"

        with patch.object(worker_api.time, "time", return_value=later), patch.object(worker_api.time, "sleep") as sleep:
            self.client.info["status"] = {"type": "active", "activeFlags": []}
            self.assertEqual("pending", worker_api.direction_state(self.client, self.worker))
            self.client.info["status"] = {"type": "idle"}
            self.client.turns.insert(0, {"id": "other", "status": "inProgress"})
            self.client.items["other"] = [user_message("Someone else's turn")]
            self.assertEqual("pending", worker_api.direction_state(self.client, self.worker))
            self.client.turns.pop(0)
            sleep.side_effect = turn_recorded
            self.assertEqual("finished", worker_api.direction_state(self.client, self.worker))

    def test_another_running_turn_does_not_hold_up_a_finished_direction(self):
        self.worker["codexDirection"] = {"id": "done-id", "previousTurn": "previous", "sentAt": 1000}
        self.client.turns = [{"id": "user-turn", "status": "inProgress"},
                             {"id": "directed", "status": "completed"},
                             {"id": "previous", "status": "completed"}]
        self.client.items = {"user-turn": [user_message("The user's own request")],
                             "directed": [user_message("Direction")], "previous": [user_message("Earlier work")]}
        self.client.items["directed"][0]["item"]["clientId"] = "done-id"
        self.client.info["status"] = {"type": "active", "activeFlags": []}
        self.assertEqual("finished", worker_api.direction_state(self.client, self.worker))

    def test_reminds_when_pending_block_identity_stays_the_same(self):
        self.client.turns = [{"id": "first", "status": "inProgress"}]
        self.client.info["status"] = {"type": "active", "activeFlags": ["waitingOnApproval"]}
        self.client.latest = [{"item": {"id": "approval-one"}}]
        with patch.object(worker_api.time, "time", return_value=1000):
            self.assertIn("waiting on approval", self.scan()[0])
            self.delivered()
        with patch.object(worker_api.time, "time", return_value=1000 + worker_api.BLOCK_REMINDER_SECONDS):
            self.assertIn("still waiting on approval", self.scan()[0])

    def test_verifies_a_full_codex_thread_at_its_original_directory(self):
        Path(self.worker["dir"]).mkdir()
        self.assertEqual(self.worker["dir"], worker_api.thread_identity(self.client, self.worker["id"])["dir"])
        self.client.info["parentThreadId"] = "another-thread"
        with self.assertRaisesRegex(ValueError, "full session"):
            worker_api.thread_identity(self.client, self.worker["id"])

    def test_reconciles_a_notice_after_a_lost_queue_acknowledgment(self):
        claim = {"sessionId": self.worker["id"], "dir": self.worker["dir"], "name": "fixture"}
        notice = self.stage / "notice"
        notice.mkdir()
        (notice / "message").write_text("RESULT: fixture completed")
        original = self.client.call
        sent = []
        started = []

        def lost_ack(method, params):
            if method == "thread/queue/add":
                sent.append(params["clientUserMessageId"])
                self.client.queue = [{"id": "operator-submission", "clientUserMessageId": "unrelated"},
                                     {"id": "anderton-notice", "clientUserMessageId": sent[0]}]
                raise TimeoutError("acknowledgment lost")
            if method == "thread/queue/start":
                started.append(params["queuedSubmissionId"])
                return {"turn": {"id": "completed-notice"}}
            return original(method, params)

        with patch.object(self.client, "call", side_effect=lost_ack):
            with self.assertRaises(TimeoutError):
                worker_api.deliver_notice(self.client, claim, notice)
            self.assertEqual(sent[0], json.loads((notice / "receipt.json").read_text())["id"])
            self.client.info["status"] = {"type": "active"}
            self.assertFalse(worker_api.deliver_notice(self.client, claim, notice))
            self.assertEqual([], started)
            self.client.info["status"] = {"type": "idle"}
            self.assertFalse(worker_api.deliver_notice(self.client, claim, notice))
            self.assertEqual(["anderton-notice"], started)
            self.client.queue = []
            self.client.turns = [{"id": "completed-notice", "status": "interrupted"}]
            self.client.items["completed-notice"] = []
            self.assertFalse(worker_api.deliver_notice(self.client, claim, notice))
            self.client.items["completed-notice"] = [user_message("RESULT: fixture completed")]
            self.client.items["completed-notice"][0]["item"]["clientId"] = sent[0]
            self.assertTrue(worker_api.deliver_notice(self.client, claim, notice))
        self.assertEqual(1, len(sent))


class SlowDaemonTest(unittest.TestCase):
    """The real Codex.call against a daemon that answers each method after a delay on a simulated clock."""

    def setUp(self):
        self.now = 0.0
        clock = patch.object(worker_api.time, "monotonic", side_effect=lambda: self.now)
        clock.start()
        self.addCleanup(clock.stop)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name).resolve()
        self.delays = {}

    def client(self):
        test = self
        sent = []

        class Transport:
            timeout = None

            def settimeout(self, seconds):
                self.timeout = seconds

            def close(self):
                pass

        transport = Transport()
        client = object.__new__(worker_api.Codex)
        client.socket = client.stream = transport
        client.request_id = 0
        client.initialize = lambda: None
        client.send = sent.append

        def receive():
            request = sent[-1]
            delay = test.delays.get(request["method"], 0)
            if delay > transport.timeout:
                test.now += transport.timeout
                raise TimeoutError("timed out")
            test.now += delay
            result = {"queuedSubmission": {"id": "submission"}} if request["method"] == "thread/queue/add" \
                else {"data": []}
            return {"id": request["id"], "result": result}

        client.receive = receive
        return client

    def run_main(self, *argv):
        with patch.object(worker_api, "Codex", return_value=self.client()), \
                patch.object(worker_api.sys, "argv", ["codex-worker.py", *argv]):
            return worker_api.main()

    def test_lists_a_worktrees_threads_that_take_longer_than_a_send(self):
        # Measured: about 9 seconds for a worktree with no threads, on a daemon holding some 600.
        self.delays["thread/list"] = 9.3
        home = str(self.directory / "codex")
        worktree = str(self.directory / "worktree")
        self.assertEqual(3, self.run_main("find", home, worktree, "--after", "",
                                          "--token", "00000000-0000-4000-8000-000000000789"))
        record = self.directory / "worker.json"
        record.write_text(json.dumps({"id": "", "name": "fixture", "dir": worktree, "codexHome": home,
                                      "codexBaseline": ""}))
        self.assertEqual(0, self.run_main("inactive", str(record)))

    def test_a_send_still_gives_up_after_five_seconds(self):
        self.delays["thread/queue/add"] = 5.5
        with self.assertRaises(TimeoutError):
            self.client().call("thread/queue/add", {"threadId": "thread", "clientUserMessageId": "id", "input": []})
        self.assertEqual(5, self.now)
        self.assertLess(self.now, worker_api.DIRECTION_LOST_AFTER_SECONDS)


if __name__ == "__main__":
    unittest.main()
