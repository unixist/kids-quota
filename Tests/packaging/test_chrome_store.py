"""Exercise exact native-host origins and store-ID propagation without installing."""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)
    return path


class ChromeStoreInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="kids-quota-store-test-")
        self.work = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def native_host(self, primary, store):
        source = (ROOT / "scripts/install.sh").read_text()
        generator = re.search(r"(?ms)^chrome_native_host_manifest\(\) \{\n.*?^\}", source).group()
        command = generator + "\nchrome_native_host_manifest \"$1\" \"$2\"\n"
        return subprocess.run(["/bin/bash", "-eu", "-c", command, "test", primary, store], capture_output=True, text=True)

    def test_native_host_accepts_only_both_exact_ids_and_deduplicates(self):
        for primary, store, expected in [
            ("a" * 32, "b" * 32, ["a" * 32, "b" * 32]),
            ("a" * 32, "a" * 32, ["a" * 32]),
            ("a" * 32, "", ["a" * 32]),
            ("", "b" * 32, ["b" * 32]),
        ]:
            with self.subTest(primary=primary, store=store):
                result = self.native_host(primary, store)
                self.assertEqual(result.returncode, 0, result.stderr)
                manifest = json.loads(result.stdout)
                self.assertEqual(manifest["allowed_origins"], [f"chrome-extension://{value}/" for value in expected])
                self.assertEqual(manifest["path"], "/Library/Application Support/KidsQuota/bin/kids-quota-bridge")
                self.assertEqual(manifest["type"], "stdio")

    def test_native_host_rejects_missing_invalid_or_injected_ids_without_output(self):
        marker = self.work / "must-not-exist"
        for primary, store in [
            ("", ""), ("a" * 31, "b" * 32), ("a" * 32, "q" * 32),
            ("a" * 32, "*"), ("a" * 32, 'b"],"unexpected":['),
            ("a" * 32, f"$(touch {marker})"), ("a" * 32, "b" * 32 + "\n"),
        ]:
            with self.subTest(primary=primary, store=store):
                result = self.native_host(primary, store)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
        self.assertFalse(marker.exists())

    def test_invalid_store_id_rejected_before_artifact_or_root_work(self):
        result = subprocess.run([
            "/bin/bash", str(ROOT / "scripts/install.sh"), "--local", "--check",
            "--artifacts", str(self.work / "missing"), "--chrome-store-extension-id", "*",
        ], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("32 letters a-p", result.stderr)
        self.assertNotIn("Missing local release", result.stderr)

    def package_fixture(self, store_id):
        repo = self.work / "repo"
        (repo / "scripts").mkdir(parents=True)
        (repo / "dist/local").mkdir(parents=True)
        (repo / "dist/local/local-release.json").write_text('{"fixture":true}')
        executable(repo / "scripts/install.sh", '#!/bin/bash\nprintf "%s\\n" "$@" > "$ARG_LOG"\n')
        executable(repo / "scripts/create-local-trust.sh", '#!/bin/bash\nexit 0\n')
        capture = self.work / "captured"
        pkgbuild = executable(self.work / "pkgbuild", '''#!/bin/bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --scripts ]]; then cp -R "$2" "$CAPTURE"; shift 2; else output="$1"; shift; fi
done
printf fixture > "$output"
''')
        source = (ROOT / "scripts/package.sh").read_text().replace("/usr/bin/pkgbuild", shlex.quote(str(pkgbuild)))
        script = executable(repo / "scripts/package.sh", source)
        env = dict(os.environ, VERSION="0.1.3", CHROME_EXTENSION_ID="a" * 32,
                   CHROME_STORE_EXTENSION_ID=store_id, CAPTURE=str(capture), ARG_LOG=str(self.work / "check.log"))
        result = subprocess.run([str(script), "--local", "--pkg-only"], env=env, capture_output=True, text=True)
        return result, capture, env

    def test_packaged_postinstall_forwards_store_id_separately_from_local_id(self):
        store_id = "b" * 32
        result, capture, env = self.package_fixture(store_id)
        self.assertEqual(result.returncode, 0, result.stderr)
        check = (self.work / "check.log").read_text().splitlines()
        self.assertEqual(check[-4:], ["--chrome-extension-id", "a" * 32, "--chrome-store-extension-id", store_id])
        self.assertEqual(check[0], "--check")
        postinstall_log = self.work / "postinstall.log"
        result = subprocess.run([str(capture / "postinstall"), "package", "/", "/"],
                                env=dict(env, ARG_LOG=str(postinstall_log)), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = postinstall_log.read_text().splitlines()
        self.assertEqual(arguments, ["--artifacts", str(capture / "artifacts"), "--local",
                                    "--chrome-extension-id", "a" * 32, "--chrome-store-extension-id", store_id])

    def test_package_rejects_store_id_injection_before_build(self):
        marker = self.work / "must-not-exist"
        result, capture, _ = self.package_fixture(f"$(touch {marker})")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Invalid Chrome Web Store extension ID", result.stderr)
        self.assertFalse(capture.exists())
        self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
