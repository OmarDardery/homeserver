import tempfile
import unittest
from pathlib import Path
import backend as b


class SecretTests(unittest.TestCase):
    def test_migration_and_round_trip(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            b.STATE = p
            b.KEY = p / "age.key"
            b.STORE = p / "runtime.enc"
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


if __name__ == "__main__":
    unittest.main()
