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
                    b.commit_update(data)
                    payload = api.call_args.args[2]
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


if __name__ == "__main__":
    unittest.main()
