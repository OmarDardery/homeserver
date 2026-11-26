import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path
import backend as b


class SecretTests(unittest.TestCase):
    def test_migration_and_round_trip(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            b.STATE = p
            b.KEY = p / "age.key"
            b.STORE = p / "runtime.enc"
            b.GITHUB_TOKEN = p / "github.token"
            b.RUNTIME = p / "run"
            b.OLD_ENV = p / "old.env"
            b.OLD_TOKEN = p / "old.token"
            b.OLD_ENV.write_text("AIOSTREAMS_AUTH=admin:preserved\n")
            b.OLD_TOKEN.write_text("example-token\n")
            b.initialize()
            data = b.decrypt()
            self.assertEqual(data["AIOSTREAMS_AUTH"], "admin:preserved")
            self.assertEqual(data[b.TOKEN], "example-token")
            self.assertNotIn(b"admin:preserved", b.STORE.read_bytes())
            b.initialize()
            self.assertEqual(data, b.decrypt())
            b.materialize(data)
            self.assertNotIn(b.TOKEN, (b.RUNTIME / "aiostreams.env").read_text())
            self.assertEqual((b.RUNTIME / "token").read_text(), "example-token\n")
            del data[b.TOKEN]
            b.materialize(data)
            self.assertFalse((b.RUNTIME / "token").exists())
            data["AIOSTREAMS_AUTH_REQUIRED"] = "false"
            with self.assertRaises(b.Invalid):
                b.validate(data)

    def test_github_commit_and_conflict(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            with patch.multiple(b, STATE=p, KEY=p/"age.key", STORE=p/"runtime.enc",
                                GITHUB_TOKEN=p/"github.token", OLD_ENV=p/"old.env",
                                OLD_TOKEN=p/"old.token"):
                b.initialize()
                old = b.STORE.read_bytes()
                token = "github_pat_" + "a" * 40
                with patch.object(b, "remote_read", return_value=None), patch.object(b, "github_api", return_value={"content":{"sha":"a"*40}}) as api:
                    b.github_connect(token)
                    payload = api.call_args.args[2]
                    self.assertEqual(b.base64.b64decode(payload["content"]), old)
                    self.assertNotIn(token, str(payload))
                data = b.decrypt()
                data["EXTRA_VAR"] = "new-value"
                with patch.object(b, "remote_read", return_value=("a"*40, old)), patch.object(b, "github_api", return_value={"content":{"sha":"b"*40}}) as api:
                    b.commit_update(data, b.decrypt())
                    payload = api.call_args.args[2]
                    self.assertEqual(payload["message"], "Secrets: set EXTRA_VAR")
                    self.assertEqual(payload["sha"], "a"*40)
                    self.assertEqual(b.decrypt_blob(b.base64.b64decode(payload["content"])), data)
                    self.assertNotIn("new-value", str(payload))
                current = b.STORE.read_bytes()
                with patch.object(b, "remote_read", return_value=("a"*40, old)), patch.object(b, "remote_write") as write:
                    with self.assertRaises(b.Invalid):
                        b.commit_update(data)
                    write.assert_not_called()
                    self.assertEqual(b.STORE.read_bytes(), current)
                with patch.object(b, "remote_read", return_value=("b"*40, old)), patch.object(b, "apply_changes") as apply:
                    b.pull_remote(data)
                    self.assertEqual(b.STORE.read_bytes(), old)
                    apply.assert_called_once()
                with self.assertRaises(b.Invalid):
                    b.encrypted_document(b'{"data":"plaintext","sops":{}}')

    def test_push_and_ensure(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            with patch.multiple(b, STATE=p, KEY=p/"age.key", STORE=p/"runtime.enc",
                                GITHUB_TOKEN=p/"github.token", OLD_ENV=p/"old.env",
                                OLD_TOKEN=p/"old.token"):
                b.initialize()
                local = b.STORE.read_bytes()
                self.assertIn("local", b.ensure_remote())
                with self.assertRaises(b.Invalid):
                    b.push_remote()
                b.GITHUB_TOKEN.write_text("github_pat_" + "a" * 40 + "\n")
                data = b.decrypt()
                data["OTHER_VAR"] = "x"
                other = b.encrypt(data)
                with patch.object(b, "remote_read", return_value=None), patch.object(b, "github_api", return_value={"content":{"sha":"a"*40}}) as api:
                    self.assertIn("Published", b.ensure_remote())
                    self.assertEqual(b.base64.b64decode(api.call_args.args[2]["content"]), local)
                with patch.object(b, "remote_read", return_value=("a"*40, local)), patch.object(b, "remote_write") as write:
                    self.assertIn("match", b.ensure_remote())
                    self.assertIn("already", b.push_remote())
                    write.assert_not_called()
                with patch.object(b, "remote_read", return_value=("a"*40, other)), patch.object(b, "remote_write") as write:
                    with self.assertRaises(b.Invalid):
                        b.ensure_remote()
                    write.assert_not_called()
                with patch.object(b, "remote_read", return_value=("a"*40, other)), patch.object(b, "github_api", return_value={"content":{"sha":"b"*40}}) as api:
                    self.assertIn("pushed", b.push_remote())
                    payload = api.call_args.args[2]
                    self.assertEqual(payload["sha"], "a"*40)
                    self.assertEqual(b.base64.b64decode(payload["content"]), local)
                    self.assertNotIn("github_pat_", str(payload))
                self.assertEqual(b.STORE.read_bytes(), local)

    def test_update_status(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            with patch.multiple(b, GITHUB_TOKEN=p/"github.token", DEPLOYED=p/"rev"):
                self.assertEqual(b.update_status()["state"], "unknown")
                b.GITHUB_TOKEN.write_text("github_pat_" + "a" * 40 + "\n")
                main = {"sha": "f" * 40}
                with patch.object(b, "github_api", return_value=main):
                    self.assertIn("unknown", b.update_status()["message"])
                    b.DEPLOYED.write_text("f" * 40 + "\n")
                    self.assertEqual(b.update_status()["state"], "current")
                b.DEPLOYED.write_text("e" * 40 + "\n")
                compare = {"ahead_by": 2, "commits": [
                    {"sha": "1" * 40, "commit": {"message": "First\n\nbody"}},
                    {"sha": "2" * 40, "commit": {"message": "Second"}}]}
                with patch.object(b, "github_api", side_effect=[main, compare]) as api:
                    status = b.update_status()
                    self.assertEqual(status["state"], "behind")
                    self.assertEqual(status["message"], "2 updates available.")
                    self.assertEqual([c["message"] for c in status["commits"]], ["Second", "First"])
                    self.assertTrue(api.call_args.kwargs["url"].endswith("/compare/" + "e" * 40 + "..." + "f" * 40))
                with patch.object(b, "github_api", return_value={"sha": "bad"}), self.assertRaises(b.Invalid):
                    b.update_status()

    def test_import_history_and_messages(self):
        base = {"BASE_URL": "https://x", "SECRET_KEY": "a" * 64,
                "AIOSTREAMS_AUTH": "admin:pw", "AIOSTREAMS_AUTH_REQUIRED": "true"}
        out = b.parse_import("# c\n\nexport NEW_ONE=\"v1\"\nOTHER='x:y'\n", base)
        self.assertEqual(out["NEW_ONE"], "v1")
        self.assertEqual(out["OTHER"], "x:y")
        self.assertNotIn("NEW_ONE", base)
        for bad in ("lower=1", "NO_SEP", "GITHUB_TOKEN=x", "SPACED=a b", "AIOSTREAMS_AUTH_REQUIRED=false"):
            with self.assertRaises(b.Invalid):
                b.parse_import(bad, base)
        changed = dict(out, SECRET_KEY="b" * 64)
        changed.pop("OTHER")
        msg = b.change_message(base | {"OTHER": "x:y"}, changed)
        self.assertEqual(msg, "Secrets: set NEW_ONE, SECRET_KEY; remove OTHER")
        self.assertNotIn("b" * 64, msg)
        rows = {r["name"]: r for r in b.describe(base)}
        self.assertFalse(rows[b.TOKEN]["configured"])
        self.assertEqual(rows[b.TOKEN]["scope"], "cloudflared")
        self.assertTrue(rows["SECRET_KEY"]["required"])
        with tempfile.TemporaryDirectory() as d:
            with patch.object(b, "GITHUB_TOKEN", Path(d) / "t"):
                self.assertEqual(b.history(), [])
                b.GITHUB_TOKEN.write_text("github_pat_x\n")
                api = [{"sha": "c" * 40, "author": None, "commit": {
                    "message": "Secrets: set A\n\nbody", "committer": {"date": "2026-01-01T00:00:00Z"},
                    "author": {"name": "Host"}}}]
                with patch.object(b, "github_api", return_value=api) as call:
                    self.assertEqual(b.history(), [{"sha": "ccccccc", "message": "Secrets: set A",
                                                    "date": "2026-01-01T00:00:00Z", "author": "Host"}])
                    self.assertEqual(call.call_args.kwargs["url"], b.GITHUB_HISTORY)
                with patch.object(b, "github_api", return_value=[{"bad": 1}]), self.assertRaises(b.Invalid):
                    b.history()


if __name__ == "__main__":
    unittest.main()
