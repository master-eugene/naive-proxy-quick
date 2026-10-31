import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
NPQ = ROOT / "console" / "npq"


class NpqTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.data = root / "data"
        self.caddyfile = root / "Caddyfile"
        self.web = root / "web"
        bindir = root / "bin"
        bindir.mkdir()
        for name in ("caddy", "systemctl"):
            tool = bindir / name
            tool.write_text("#!/bin/sh\nexit 0\n")
            tool.chmod(0o755)
        qrencode = bindir / "qrencode"
        qrencode.write_text("#!/bin/sh\nprintf 'QR-CODE\\n'\n")
        qrencode.chmod(0o755)
        self.env = {
            **os.environ,
            "NPQ_DATA_DIR": str(self.data),
            "NPQ_CADDYFILE": str(self.caddyfile),
            "NPQ_WEB_ROOT": str(self.web),
            "PATH": f"{bindir}:{os.environ.get('PATH', '')}",
        }

    def tearDown(self):
        self.tmp.cleanup()

    def run_npq(self, *args, ok=True):
        result = subprocess.run([str(NPQ), "--json", *args], env=self.env, text=True, capture_output=True)
        if ok and result.returncode:
            self.fail(result.stderr or result.stdout)
        return result, json.loads(result.stdout)

    def test_init_and_user_lifecycle(self):
        _, initialized = self.run_npq("init", "--domain", "proxy.example.com", "--port", "443", "--no-reload")
        self.assertEqual(initialized["server"]["domain"], "proxy.example.com")
        self.assertTrue(initialized["created"]["link"].startswith("naive+https://user-1:"))
        self.assertTrue(initialized["created"]["proxy"].startswith("https://user-1:"))
        config = self.caddyfile.read_text()
        self.assertIn(":443, proxy.example.com", config)
        self.assertIn("https_port 443", config)
        self.assertIn("probe_resistance", config)

        _, added = self.run_npq("user", "add", "--name", "phone")
        user_id = str(added["user"]["id"])
        self.assertIn("@proxy.example.com", added["user"]["link"])
        self.run_npq("user", "disable", "--id", user_id)
        _, listed = self.run_npq("user", "list")
        self.assertFalse(next(user for user in listed["users"] if str(user["id"]) == user_id)["enabled"])
        self.run_npq("user", "remove", "--id", user_id)

    def test_optional_reverse_proxy_camouflage(self):
        self.run_npq("init", "--domain", "proxy.example.com", "--port", "443", "--decoy-url", "https://example.org", "--no-reload")
        config = self.caddyfile.read_text()
        self.assertIn('reverse_proxy "https://example.org"', config)
        self.assertIn("header_up X-Forwarded-Host {host}", config)
        self.assertNotIn("file_server", config)

    def test_invalid_camouflage_url_is_rejected(self):
        result, payload = self.run_npq("init", "--domain", "proxy.example.com", "--port", "443", "--decoy-url", "file:///etc/passwd", "--no-reload", ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("http(s)", payload["error"])

    def test_last_enabled_user_is_protected(self):
        self.run_npq("init", "--domain", "proxy.example.com", "--port", "8443", "--no-reload")
        result, payload = self.run_npq("user", "disable", "--id", "1", ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("last enabled user", payload["error"].lower())

    def test_interactive_user_info_and_exit(self):
        self.run_npq("init", "--domain", "proxy.example.com", "--port", "443", "--no-reload")
        result = subprocess.run(
            [str(NPQ)],
            env=self.env,
            input="4\n1\n1\n4\n1\n2\n4\n1\n3\n7\n",
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreaterEqual(result.stdout.count("ID  Status    Name"), 3)
        self.assertIn("1  QR code", result.stdout)
        self.assertIn("QR-CODE", result.stdout)
        self.assertIn("Karing link:", result.stdout)
        self.assertIn("Sing-box JSON:", result.stdout)
        self.assertTrue(result.stdout.rstrip().endswith("Bye!"))


if __name__ == "__main__":
    unittest.main()
