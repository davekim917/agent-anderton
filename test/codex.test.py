import importlib.util
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

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def call(self, method, params):
        assert method == "thread/read"
        assert params["threadId"] == self.info["id"]
        return {"thread": self.info}

    def pages(self, method, **params):
        assert params["threadId"] == self.info["id"]
        if method == "thread/turns/list":
            return iter(self.turns)
        assert method == "thread/items/list"
        return iter(self.items[params["turnId"]])


def message(text, phase="final_answer"):
    return {"item": {"type": "agentMessage", "text": text, "phase": phase}}


class WorkerTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        directory = Path(temporary.name)
        self.state = directory / "state"
        self.stage = directory / "stage"
        self.state.mkdir()
        self.stage.mkdir()
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
        self.assertIn("waiting on approval", self.scan()[0])
        self.delivered()
        self.assertEqual([], self.scan())
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


if __name__ == "__main__":
    unittest.main()
