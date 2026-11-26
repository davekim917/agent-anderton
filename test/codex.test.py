import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import time
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
        self.adds = []
        self.starts = []
        self.queue_paused = False
        self.checked_queue = False
        self.listings = []
        self.listed = []
        self.others = {}
        self.loaded = []

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def call(self, method, params, timeout=None):
        if method == "thread/turns/list":
            if params.get("sortDirection") == "asc":
                return {"data": [{"id": params["threadId"]}]}
            return {"data": self.turns[:params["limit"]]}
        if method == "thread/items/list":
            return {"data": self.latest}
        if method == "thread/queue/list":
            self.checked_queue = True
            return {"data": self.queue}
        if method == "thread/queue/add":
            entry = {"id": f"submission-{len(self.adds)}", **params}
            self.adds.append(entry)
            self.queue.append(entry)
            if self.info["status"]["type"] == "idle" and not self.queue_paused:
                self.info["status"] = {"type": "active"}
            return {"queuedSubmission": entry}
        if method == "thread/queue/start":
            selected = params.get("queuedSubmissionId", self.queue[0]["id"])
            entry = next(item for item in self.queue if item["id"] == selected)
            self.starts.append(entry["id"])
            self.start_direction(entry, "inProgress")
            self.info["status"] = {"type": "active"}
            return {"turn": self.turns[0]}
        if method == "thread/resume":
            self.info["status"] = {"type": "idle"}
            return {"thread": self.info}
        assert method == "thread/read"
        if params["threadId"] in self.others:
            return {"thread": self.others[params["threadId"]]}
        assert params["threadId"] == self.info["id"]
        return {"thread": self.info}

    def start_direction(self, entry, status):
        self.queue.remove(entry)
        self.turns.insert(0, {"id": entry["id"], "status": status})
        self.items[entry["id"]] = [user_message("Direction")]
        self.items[entry["id"]][0]["item"]["clientId"] = entry["clientUserMessageId"]

    def pages(self, method, timeout=None, **params):
        if method == "thread/list":
            self.listings.append({**params, "timeout": timeout})
            threads = [thread for thread in self.threads if params.get("cwd", thread["cwd"]) == thread["cwd"]]
            return (self.listed.append(thread["id"]) or thread for thread in threads)
        if method == "thread/turns/list":
            return iter(self.turns)
        if method == "thread/queue/list":
            return iter(self.queue)
        if method == "thread/loaded/list":
            return iter(self.loaded)
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

    def test_readoption_uses_fresh_baseline_without_resetting_takeover_bookmarks(self):
        self.client.turns = [{"id": "before-release", "status": "completed"}]
        self.client.items["before-release"] = [message("RESULT: before release")]
        self.worker["codexAdoptionId"] = "00000000-0000-4000-8000-000000000001"
        self.assertIn("before release", self.scan()[0])
        self.delivered()
        self.assertEqual([], self.scan())

        self.worker.update(codexAdoptionId="00000000-0000-4000-8000-000000000002",
                           codexBaselineTurn="while-released")
        self.client.turns[:0] = [{"id": "after-adoption", "status": "completed"},
                                {"id": "while-released", "status": "completed"}]
        self.client.items["after-adoption"] = [message("RESULT: after adoption")]
        self.client.items["while-released"] = [message("RESULT: while released")]
        events = self.scan()
        self.assertEqual(["RESULT: after adoption"], [event.splitlines()[-1] for event in events])
        self.delivered()
        self.assertEqual([], self.scan())

    def test_pending_notice_and_sweep_share_the_same_blocker_receipt(self):
        self.client.turns = [{"id": "current-turn", "status": "inProgress"}]
        self.client.info["status"] = {"type": "active", "activeFlags": ["waitingOnApproval"]}
        self.client.latest = [{"item": {"id": "approval-first"}}]
        self.assertIn("waiting on approval", self.scan()[0])
        original_call = self.client.call
        reported = self.state / "reported"
        with patch.object(self.client, "call", side_effect=lambda method, params:
                          {"data": self.client.turns} if method == "thread/turns/list" else original_call(method, params)):
            with contextlib.redirect_stdout(io.StringIO()) as captured:
                worker_api.blocker_during_notice(self.worker, self.stage, self.state)
            self.assertEqual("", captured.getvalue())
            self.client.latest = [{"item": {"id": "approval-next"}}]
            with contextlib.redirect_stdout(io.StringIO()) as captured:
                worker_api.blocker_during_notice(self.worker, self.stage, self.state)
            self.assertIn("approval-next", captured.getvalue())
            reported.write_text(captured.getvalue())
        self.delivered()
        with patch.dict(os.environ, {"ANDERTON_REPORTED_BLOCKS": str(reported)}):
            self.assertEqual([], self.scan())
            self.delivered()
            self.client.latest = [{"item": {"id": "approval-third"}}]
            self.assertIn("waiting on approval", self.scan()[0])

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

    def test_reports_a_usage_limit_and_offers_only_a_latest_finished_one_for_a_move(self):
        limit = {"message": "You've hit your usage limit.", "codexErrorInfo": "usageLimitExceeded"}
        for turns, moved in [
            ([{"id": "limited", "status": "failed", "error": limit}], True),
            ([{"id": "limited", "status": "failed", "error": {"message": "You've hit your usage limit. Try later."}}],
             True),
            ([{"id": "later", "status": "inProgress"}, {"id": "limited", "status": "failed", "error": limit}], False),
            ([{"id": "later", "status": "completed"}, {"id": "limited", "status": "failed", "error": limit}], False),
            ([{"id": "other", "status": "failed", "error": {"message": "stream disconnected"}}], False),
            ([{"id": "other", "status": "failed",
               "error": {"message": "Did not hit your usage limit; connection reset"}}], False),
            ([{"id": "other", "status": "failed",
               "error": {"message": "You've hit your usage limit.", "codexErrorInfo": "other"}}], False),
        ]:
            with self.subTest(turns=[turn["id"] for turn in turns], moved=moved):
                for stale in self.state.iterdir():
                    stale.unlink()
                self.client.turns = turns
                self.client.items = {turn["id"]: [] for turn in turns}
                limited = []
                events = worker_api.sweep_worker(self.worker, self.state, self.stage, limited)
                self.assertEqual([self.worker] if moved else [], limited)
                reported = any(f"failed at the usage limit of {self.worker['codexHome']}" in e for e in events)
                self.assertEqual(any(turn["id"] == "limited" for turn in turns), reported)

    def test_a_limit_is_offered_again_after_its_report_until_its_move_ran(self):
        self.client.turns = [{"id": "limited", "status": "failed", "error": {"message": "You've hit your usage limit."}}]
        self.client.items = {"limited": []}
        limited = []
        self.assertTrue(worker_api.sweep_worker(self.worker, self.state, self.stage, limited))
        self.delivered()
        limited = []
        self.assertEqual([], worker_api.sweep_worker(self.worker, self.state, self.stage, limited))
        self.assertEqual([self.worker], limited)
        with patch.object(worker_api.time, "time", return_value=10_000):
            self.worker["codexFailover"] = {"turn": "limited", "at": 10_000 - 60, "moved": False}
            self.assertFalse(worker_api.failover_due(self.worker, "limited"))
            self.worker["codexFailover"]["at"] = 10_000 - worker_api.FAILOVER_RETRY_SECONDS
            self.assertTrue(worker_api.failover_due(self.worker, "limited"))
            self.worker["codexFailover"]["moved"] = True
            self.assertFalse(worker_api.failover_due(self.worker, "limited"))
            self.worker["codexFailover"].update(moved=False, resumed=True)
            self.assertFalse(worker_api.failover_due(self.worker, "limited"))
            self.worker["codexFailover"].update(moved=True, resumed=False)
            limited = []
            worker_api.sweep_worker(self.worker, self.state, self.stage, limited)
            self.assertEqual([], limited)
            self.assertTrue(worker_api.failover_due(self.worker, "a-later-limit"))

    def test_unloaded_waits_for_the_daemon_to_let_go_of_the_thread(self):
        self.record.write_text(json.dumps(self.worker))
        self.client.loaded = [self.worker["id"]]

        def unloaded(*extra):
            with patch.object(worker_api.sys, "argv", ["codex-worker.py", "unloaded", str(self.record), *extra]):
                return worker_api.main()

        self.assertEqual(3, unloaded())
        clock = iter([0, 0, 1, 3])
        with patch.object(worker_api.time, "monotonic", side_effect=lambda: next(clock)), \
                patch.object(worker_api.time, "sleep", side_effect=lambda _: self.client.loaded.clear()):
            self.assertEqual(0, unloaded("--wait", "5"))

    def test_loaded_waits_for_a_daemon_to_load_the_thread_even_before_its_socket_answers(self):
        def loaded(*extra):
            with patch.object(worker_api.sys, "argv", ["codex-worker.py", "loaded", "/next-home", self.worker["id"], *extra]):
                return worker_api.main()

        self.assertEqual(3, loaded())
        answers = iter([OSError("no socket yet"), None])

        def connect(home):
            answer = next(answers)
            if answer is not None:
                raise answer
            self.client.loaded = [self.worker["id"]]
            return self.client

        clock = iter([0, 0, 1, 2])
        with patch.object(worker_api, "Codex", side_effect=connect), \
                patch.object(worker_api.time, "monotonic", side_effect=lambda: next(clock)), \
                patch.object(worker_api.time, "sleep"):
            self.assertEqual(0, loaded("--wait", "5"))

    def test_still_limited_only_while_the_limited_turn_is_latest_and_nothing_follows_it(self):
        self.record.write_text(json.dumps(self.worker))

        def still(turn):
            with patch.object(worker_api.sys, "argv", ["codex-worker.py", "still-limited", str(self.record), turn]):
                return worker_api.main()

        self.client.turns = [{"id": "limited", "status": "failed", "error": {"message": "You've hit your usage limit."}}]
        self.assertEqual(0, still("limited"))
        self.client.info["status"] = {"type": "systemError"}
        self.assertEqual(0, still("limited"))
        self.client.info["status"] = {"type": "idle"}
        self.assertEqual(3, still("older"))
        self.client.queue = [{"id": "direction"}]
        self.assertEqual(3, still("limited"))
        self.client.queue = []
        self.client.info["status"] = {"type": "active"}
        self.assertEqual(3, still("limited"))

    def test_limited_names_the_turn_and_limit_only_while_the_thread_waits_on_nothing(self):
        self.record.write_text(json.dumps(self.worker))
        self.client.turns = [{"id": "limited", "status": "failed",
                              "error": {"message": "You've hit your usage limit. Try again at 9:00 PM."}}]

        def limited():
            with contextlib.redirect_stdout(io.StringIO()) as out, \
                    patch.object(worker_api.sys, "argv", ["codex-worker.py", "limited", str(self.record)]):
                status = worker_api.main()
            return status, out.getvalue()

        self.assertEqual((0, "limited\nYou've hit your usage limit. Try again at 9:00 PM.\n"), limited())
        # A loaded thread whose turn failed stays systemError, with its pane still attached.
        self.client.info["status"] = {"type": "systemError"}
        self.assertEqual((0, "limited\nYou've hit your usage limit. Try again at 9:00 PM.\n"), limited())
        self.client.info["status"] = {"type": "idle"}
        self.client.queue = [{"id": "direction"}]
        self.assertEqual((3, ""), limited())
        self.client.queue = []
        self.client.info["status"] = {"type": "active"}
        self.assertEqual((3, ""), limited())

    def test_resume_on_resumes_the_thread_in_its_worktree_and_leaves_the_record_to_the_caller(self):
        self.record.write_text(json.dumps(self.worker))
        calls = []
        original = self.client.call
        self.client.call = lambda method, params, timeout=None: calls.append((method, params)) or original(method, params)

        def resume_on():
            with patch.object(worker_api.sys, "argv", ["codex-worker.py", "resume-on", str(self.record), "/next-home"]):
                return worker_api.main()

        self.assertEqual(0, resume_on())
        self.assertEqual(("thread/resume", {"threadId": self.worker["id"], "cwd": self.worker["dir"],
                                            "excludeTurns": True}), calls[0])
        worker_api.Codex.assert_called_with(Path("/next-home"))
        self.assertEqual(self.worker["codexHome"], json.loads(self.record.read_text())["codexHome"])
        self.client.info["cwd"] = "/elsewhere"
        with self.assertRaisesRegex(ValueError, "identity does not match"):
            resume_on()

    def test_a_stopped_move_is_due_at_once_on_the_next_sweep(self):
        self.worker["codexFailover"] = {"turn": "limited", "at": time.time(), "moved": False, "stage": "stopped"}
        self.assertTrue(worker_api.failover_due(self.worker, "limited"))

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
        caller_home = Path(self.worker["codexHome"]).parent / "caller-home"
        with patch.object(worker_api.sys, "argv", ["codex-worker.py", "launch-matches", str(self.record), thread, str(caller_home)]):
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
        # Read from the home the caller's thread runs on, not the one the launch started on: a thread can resume elsewhere.
        self.assertTrue(worker_api.Codex.call_args_list)
        self.assertTrue(all(call.args == (caller_home,) for call in worker_api.Codex.call_args_list))

    def test_launch_match_in_another_checkout_is_a_mismatch_not_an_unknown(self):
        thread = self.worker["id"]
        token = "00000000-0000-4000-8000-000000000789"
        Path(self.worker["dir"]).mkdir()
        elsewhere = Path(self.worker["dir"]).parent / "elsewhere"
        elsewhere.mkdir()
        self.record.write_text(json.dumps({**self.worker, "dir": str(elsewhere), "codexLaunchToken": token}))
        self.client.items[thread] = [user_message(f"Anderton launch {token}\n\nBrief")]
        with patch.object(worker_api.sys, "argv", ["codex-worker.py", "launch-matches", str(self.record), thread,
                                                  self.worker["codexHome"]]):
            self.assertEqual(3, worker_api.main())

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

    def test_definitively_rejected_add_removes_only_its_entry(self):
        first = self.send("Keep this direction")
        original = self.client.call

        def reject_add(method, params):
            if method == "thread/queue/add":
                prior, attempt = self.saved_directions()
                self.assertEqual(first, prior)
                self.assertTrue(attempt["unconfirmed"])
                self.assertEqual(params["clientUserMessageId"], attempt["clientUserMessageId"])
                raise worker_api.RequestRejected(method, {"code": -32600, "message": "invalid request"})
            return original(method, params)

        with patch.object(self.client, "call", side_effect=reject_add), self.assertRaises(worker_api.RequestRejected):
            self.message_command("Direction")
        self.assertEqual([first], self.saved_directions())
        self.assertEqual(self.client.adds, self.client.queue)

    def saved_directions(self):
        return json.loads(self.record.read_text())["codexDirections"]

    def lose_add_reply(self, applied=True):
        self.record.write_text(json.dumps(self.worker))
        original = self.client.call

        def drop(method, params):
            if method == "thread/queue/add":
                saved = self.saved_directions()[-1]
                self.assertTrue(saved["unconfirmed"])
                self.assertEqual(params["clientUserMessageId"], saved["clientUserMessageId"])
                if applied:
                    original(method, params)
                raise TimeoutError("add reply unavailable")
            return original(method, params)

        with contextlib.redirect_stderr(io.StringIO()) as report, patch.object(self.client, "call", side_effect=drop):
            self.assertEqual(4, self.message_command("Direction"))
        first = self.saved_directions()[-1]
        self.assertIn(f"Direction {first['id']} is unconfirmed", report.getvalue())
        self.assertTrue(first["unconfirmed"])
        self.worker = json.loads(self.record.read_text())
        return first

    def check_status_verdict(self, direction, verdict):
        with contextlib.redirect_stderr(io.StringIO()) as report:
            self.assertEqual(0, self.worker_command("state", "--prune"))
        self.assertIn(f"Direction {direction['id']}: {verdict}.", report.getvalue())

    def test_lost_add_reply_exits_four_and_status_reports_queued(self):
        self.client.info["status"] = {"type": "notLoaded"}
        first = self.lose_add_reply()
        self.assertEqual(first["clientUserMessageId"], self.client.queue[0]["clientUserMessageId"])
        self.check_status_verdict(first, "queued")
        self.assertEqual("idle", self.client.info["status"]["type"])
        saved, = self.saved_directions()
        self.assertEqual(first["id"], saved["id"])
        self.assertFalse(saved.get("unconfirmed"))
        self.assertEqual(1, len(self.client.adds))

    def test_lost_add_reply_remains_visible_to_status_after_a_later_send(self):
        first = self.lose_add_reply()
        self.client.start_direction(self.client.queue[0], "completed")
        self.assertEqual(1, self.worker_command("inactive", "--prune"))
        latest = self.send("Next direction")
        self.assertEqual([first, latest], self.saved_directions())
        self.check_status_verdict(first, "ran")
        self.assertEqual([latest], self.saved_directions())

    def test_status_reports_never_arrived_after_two_idle_looks_past_the_grace_period(self):
        with patch.object(worker_api.time, "time", return_value=1000):
            first = self.lose_add_reply(applied=False)
            self.check_status_verdict(first, "still unconfirmed")
        self.assertEqual([first], self.saved_directions())
        with patch.object(worker_api.time, "time", return_value=1060), patch.object(worker_api.time, "sleep") as sleep:
            self.check_status_verdict(first, "never arrived")
            self.check_status_verdict(first, "never arrived")
        sleep.assert_called_once_with(worker_api.DIRECTION_RECHECK_SECONDS)
        self.assertEqual([first["id"]], [entry["id"] for entry in self.saved_directions()])
        self.assertEqual([], self.client.adds)
        self.assertEqual(0, self.worker_command("inactive", "--prune"))
        self.assertEqual(0, self.worker_command("inactive", "--directions-only", "--prune"))
        with contextlib.redirect_stderr(io.StringIO()) as report:
            self.assertEqual(0, self.message_command("Next direction"))
            self.assertEqual(0, self.worker_command("state", "--prune"))
        self.assertNotIn(first["id"], report.getvalue())
        self.assertNotIn(first["id"], [entry["id"] for entry in self.saved_directions()])

    def test_confirmed_send_resumes_unloaded_worker_before_reconciling_earlier_directions(self):
        self.send("Earlier direction")
        self.client.info["status"] = {"type": "notLoaded"}
        calls = []
        original_call = self.client.call

        def call(method, params):
            calls.append(method)
            return original_call(method, params)

        def fail_queue_listing(method, **_):
            calls.append(method)
            self.assertEqual("thread/queue/list", method)
            raise TimeoutError("queue list unavailable")

        with patch.object(self.client, "call", side_effect=call), patch.object(self.client, "pages", fail_queue_listing):
            second = self.send("Next direction")
        add = calls.index("thread/queue/add")
        self.assertEqual(["thread/resume", "thread/queue/list"], calls[add + 1:add + 3])
        self.assertEqual("thread/queue/list", calls[-1])
        self.assertFalse(second.get("unconfirmed"))

    def test_acknowledged_add_starts_the_head_of_a_paused_queue(self):
        self.client.queue_paused = True
        self.client.queue = [{"id": "older-submission", "clientUserMessageId": "older-message"}]
        new = self.send("Next direction")
        self.assertEqual(["older-submission"], self.client.starts)
        self.assertEqual([new["clientUserMessageId"]], [entry["clientUserMessageId"] for entry in self.client.queue])

    def test_acknowledged_add_skips_start_when_new_entry_is_already_dispatched(self):
        original = self.client.call

        def dispatch(method, params):
            result = original(method, params)
            if method == "thread/queue/add":
                self.client.start_direction(result["queuedSubmission"], "completed")
                self.client.info["status"] = {"type": "idle"}
            return result

        with patch.object(self.client, "call", side_effect=dispatch):
            self.send("Direction")
        self.assertEqual([], self.client.starts)

    def assert_dispatch_failure(self, status, target, diagnostic):
        self.client.queue_paused = True
        self.client.info["status"] = {"type": status}
        self.record.write_text(json.dumps(self.worker))
        original = self.client.call

        def fail(method, params):
            if method == target:
                raise TimeoutError("dispatch reply unavailable")
            return original(method, params)

        with contextlib.redirect_stderr(io.StringIO()) as report, patch.object(self.client, "call", side_effect=fail):
            self.assertEqual(1, self.message_command("Direction"))
        self.assertIn(diagnostic, report.getvalue())
        self.assertIn("Direction was queued", report.getvalue())
        saved, = self.saved_directions()
        self.assertFalse(saved.get("unconfirmed"))
        self.assertEqual(saved["clientUserMessageId"], self.client.queue[-1]["clientUserMessageId"])

    def test_acknowledged_send_exits_nonzero_when_resume_fails(self):
        self.assert_dispatch_failure("notLoaded", "thread/resume", "Could not resume worker")

    def test_acknowledged_send_exits_nonzero_when_start_fails(self):
        self.assert_dispatch_failure("idle", "thread/queue/start", "Could not start worker queue")

    def worker_command(self, command, *options):
        with patch.object(worker_api.sys, "argv", ["codex-worker.py", command, str(self.record), *options]):
            return worker_api.main()

    def send(self, text):
        if not self.record.exists():
            self.record.write_text(json.dumps(self.worker))
        self.assertEqual(0, self.message_command(text))
        self.worker = json.loads(self.record.read_text())
        return self.worker["codexDirections"][-1]

    def message_command(self, text):
        with patch.object(worker_api.sys, "argv", [
            "codex-worker.py", "message", str(self.record), "--", text,
        ]):
            return worker_api.main()

    def test_appends_three_directions_and_prunes_only_the_finished_one(self):
        # Exercise the second and third sends even on an implementation that refuses them.
        for text in ("First", "Second", "Third"):
            with self.subTest(text=text):
                self.send(text)
        tracked = self.worker["codexDirections"]
        self.assertEqual(3, len({entry["id"] for entry in tracked}))
        self.assertTrue(all(isinstance(entry["sentAt"], int) for entry in tracked))
        self.assertEqual([entry["clientUserMessageId"] for entry in self.client.queue],
                         [entry["clientUserMessageId"] for entry in tracked])
        self.assertEqual(["First", "Second", "Third"],
                         [entry["input"][0]["text"].split("\n\n", 1)[1] for entry in self.client.queue])

        self.client.start_direction(self.client.queue[0], "completed")
        with patch.object(worker_api.sys, "argv", ["codex-worker.py", "inactive", str(self.record), "--prune"]):
            self.assertEqual(1, worker_api.main())
        self.assertEqual(tracked[1:], json.loads(self.record.read_text())["codexDirections"])

    def test_lost_direction_does_not_block_or_discard_a_queued_direction(self):
        self.worker["codexDirections"] = [
            {"id": "attempt", "clientUserMessageId": "lost-id", "previousTurn": None, "sentAt": 1000},
        ]
        with patch.object(worker_api.time, "time", return_value=1005), patch.object(worker_api.time, "sleep"):
            self.assertFalse(worker_api.is_inactive(self.client, self.worker))
            queued = self.send("Still queued")
            self.assertEqual(2, len(self.worker["codexDirections"]))
        later = 1000 + worker_api.DIRECTION_LOST_AFTER_SECONDS
        self.client.info["status"] = {"type": "idle"}
        with patch.object(worker_api.time, "time", return_value=later), patch.object(worker_api.time, "sleep") as sleep:
            self.assertEqual(0, self.worker_command("state", "--prune"))
            latest = self.send("Next")
        sleep.assert_called_once_with(worker_api.DIRECTION_RECHECK_SECONDS)
        self.assertEqual([queued, latest], self.worker["codexDirections"])

    def test_legacy_direction_is_migrated_when_appending(self):
        self.worker["codexDirection"] = {"id": "legacy", "previousTurn": None, "sentAt": 1000}
        self.client.queue = [{"id": "legacy-submission", "clientUserMessageId": "legacy"}]
        new = self.send("Append")
        self.assertNotIn("codexDirection", self.worker)
        self.assertEqual([{"id": "legacy", "clientUserMessageId": "legacy", "previousTurn": None, "sentAt": 1000}, new],
                         self.worker["codexDirections"])

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
            self.assertFalse(worker_api.is_inactive(self.client, self.worker))
            self.client.info["status"] = {"type": "idle"}
            self.client.turns.insert(0, {"id": "other", "status": "inProgress"})
            self.client.items["other"] = [user_message("Someone else's turn")]
            self.assertFalse(worker_api.is_inactive(self.client, self.worker))
            self.client.turns.pop(0)
            sleep.side_effect = turn_recorded
            self.assertTrue(worker_api.is_inactive(self.client, self.worker))

    def test_another_running_turn_does_not_hold_up_a_finished_direction(self):
        self.worker["codexDirection"] = {"id": "done-id", "previousTurn": "previous", "sentAt": 1000}
        self.client.turns = [{"id": "user-turn", "status": "inProgress"},
                             {"id": "directed", "status": "completed"},
                             {"id": "previous", "status": "completed"}]
        self.client.items = {"user-turn": [user_message("The user's own request")],
                             "directed": [user_message("Direction")], "previous": [user_message("Earlier work")]}
        self.client.items["directed"][0]["item"]["clientId"] = "done-id"
        self.client.info["status"] = {"type": "active", "activeFlags": []}
        worker_api.refresh_directions(self.client, self.worker)
        self.assertEqual([], self.worker["codexDirections"])

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


    def inbound(self, *options):
        self.record.write_text(json.dumps(self.worker))
        with contextlib.redirect_stdout(io.StringIO()) as out:
            status = self.worker_command("inbound-since-report", *options)
        return status, json.loads(out.getvalue() or '{"messages": null}')["messages"]

    def reported_launch(self):
        self.worker["codexLaunchToken"] = "6f1c2b9e-0000-4000-8000-00000000abcd"
        launch = self.worker["id"]
        self.client.turns = [{"id": launch, "status": "completed"}]
        self.client.items = {launch: [user_message("Anderton launch 6f1c2b9e-0000-4000-8000-00000000abcd\n\nFix the login."),
                                      message("RESULT: PR ready, login test passes")]}

    def typed_turn(self, turn, text, at_ms, status="completed"):
        typed = user_message(text)
        typed["item"]["clientId"] = f"tui-{turn}"
        if at_ms is not None:
            typed["startedAtMs"] = typed["completedAtMs"] = at_ms
        self.client.turns.insert(0, {"id": turn, "status": status})
        self.client.items[turn] = [typed, message("Looking into it.")]

    def test_a_typed_turn_after_the_last_report_holds_retirement_until_reviewed_through_it(self):
        self.reported_launch()
        self.assertEqual((0, []), self.inbound())
        self.typed_turn("follow-up", "Also add the retry check.\nThen open a second PR.", 1795000000250)
        self.assertEqual((4, [{"at": "2026-11-18T11:06:40.250Z", "from": "the user", "line": "Also add the retry check."}]),
                         self.inbound())
        self.assertEqual(4, self.inbound("--reviewed-through", "2026-11-18T11:06:40Z")[0])
        self.assertEqual((0, []), self.inbound("--reviewed-through", "2026-11-18T11:06:41Z"))

    def test_a_typed_turn_still_running_holds_retirement(self):
        self.reported_launch()
        self.typed_turn("running", "Wait, check the staging logs first.", 1795000000250, status="inProgress")
        self.assertEqual(4, self.inbound()[0])

    def test_a_report_after_a_typed_turn_clears_it(self):
        self.reported_launch()
        self.typed_turn("follow-up", "Also add the retry check.", 1795000000250)
        self.client.items["follow-up"][-1] = message("RESULT: retry check added in the second PR")
        self.assertEqual((0, []), self.inbound())

    def test_a_question_block_or_answer_after_a_typed_turn_leaves_it_held(self):
        for kind in ("QUESTION", "ANSWER", "BLOCKED"):
            with self.subTest(kind=kind):
                self.reported_launch()
                self.typed_turn("follow-up", "Also add the retry check.", 1795000000250)
                self.client.items["follow-up"][-1] = message(f"{kind}: the retry check or a second PR?")
                self.assertEqual(4, self.inbound()[0])

    def test_the_andertons_directions_after_the_last_report_do_not_hold_it_after_they_are_pruned(self):
        self.reported_launch()
        self.record.write_text(json.dumps(self.worker))
        direction = self.send("Rebase on main")
        self.client.start_direction(self.client.queue[0], "completed")
        self.worker["codexDirections"] = []
        self.assertEqual((0, []), self.inbound())
        self.assertIn(direction["clientUserMessageId"], self.worker["codexDirectionLedger"]["ids"])

    def test_a_direction_from_before_the_ledger_is_the_andertons_by_its_text(self):
        self.reported_launch()
        self.typed_turn("old-direction", worker_api.DIRECTION_PREFIX + "Rebase on main", 1795000000250)
        self.assertEqual((0, []), self.inbound())

    def test_on_a_ledger_record_text_never_makes_a_message_the_andertons(self):
        self.reported_launch()
        self.worker["codexDirectionLedger"] = {"ids": []}
        self.typed_turn("direction-text", worker_api.DIRECTION_PREFIX + "Rebase on main", 1795000000250)
        self.assertEqual(4, self.inbound()[0])
        self.client.turns.pop(0)
        self.typed_turn("launch-text", "Anderton launch 6f1c2b9e-0000-4000-8000-00000000abcd\n\nAlso fix logout.", 1795000000250)
        self.assertEqual(4, self.inbound()[0])

    def test_an_item_with_no_time_of_its_own_is_cleared_only_through_its_turns_end(self):
        self.reported_launch()
        self.typed_turn("running", "Wait, check the staging logs first.", None, status="inProgress")
        self.client.turns[0]["startedAt"] = 1795000000
        self.assertEqual(4, self.inbound("--reviewed-through", "2026-11-18T11:06:43Z")[0])
        self.client.turns[0].update(status="interrupted", completedAt=1795000010)
        self.assertEqual(4, self.inbound("--reviewed-through", "2026-11-18T11:06:43Z")[0])
        self.assertEqual((0, []), self.inbound("--reviewed-through", "2026-11-18T11:06:50Z"))

    def test_a_worker_with_no_thread_cannot_be_read(self):
        self.worker["id"] = ""
        with self.assertRaisesRegex(ValueError, "names no Codex thread"):
            self.inbound()


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
