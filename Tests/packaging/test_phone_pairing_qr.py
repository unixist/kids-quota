"""Offline QR generation and filesystem protection checks; only synthetic tokens."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "The QR utility uses macOS Core Image.")
class PhonePairingQRTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="kids-quota-qr-build-")
        cls.binary = Path(cls.build.name) / "pairing-qr"
        cls.decoder = Path(cls.build.name) / "verify-qr"
        # Build once so every rejection test exercises the actual CLI cheaply.
        compiled = subprocess.run(["swiftc", "-module-cache-path", str(Path(cls.build.name) / "modules"),
                        str(ROOT / "scripts/phone-pairing-qr.swift"), "-o", str(cls.binary)],
                       capture_output=True)
        if compiled.returncode:
            raise RuntimeError(compiled.stderr.decode())
        source = Path(cls.build.name) / "verify.swift"
        source.write_text(r'''
import Foundation
import CoreImage
let image = CIImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!
let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(options: [.useSoftwareRenderer: true]), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
let codes = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
guard codes.count == 1, let parts = URLComponents(string: codes[0]), parts.scheme == "kidsquota", parts.host == "pair",
      let query = parts.queryItems, query.count == 1, query[0].name == "data", let payload = query[0].value else { exit(1) }
var base64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
guard let data = Data(base64Encoded: base64), let actual = try JSONSerialization.jsonObject(with: data) as? NSDictionary,
      let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as? NSDictionary,
      actual == expected else { exit(2) }
''')
        subprocess.run(["swiftc", "-module-cache-path", str(Path(cls.build.name) / "modules"),
                        str(source), "-o", str(cls.decoder)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="kids-quota-qr-")
        self.addCleanup(self.directory.cleanup)
        self.parent = Path(self.directory.name)
        self.parent.chmod(0o700)
        self.input = self.parent / "parent-1.json"
        self.output = self.input.with_suffix(".png")
        self.document = {"schemaVersion": 1, "endpoint": "https://synthetic-test-relay.run.app",
                         "familyName": "Test family", "readToken": "syntheticTestToken" + "s" * 26}
        self.save()

    def save(self):
        self.input.write_text(json.dumps(self.document))
        self.input.chmod(0o600)

    def invoke(self, path=None):
        result = subprocess.run([str(self.binary), str(path or self.input)], capture_output=True, timeout=15)
        output = result.stdout + result.stderr
        self.assertNotIn(self.document["readToken"].encode(), output)
        self.assertNotIn(b"kidsquota://pair?data=", output)
        return result

    def test_creates_private_scannable_png_with_exact_pairing_document(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(self.output.read_bytes()[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.parent.stat().st_mode), 0o700)
        checked = subprocess.run([str(self.decoder), str(self.output), str(self.input)], capture_output=True, timeout=15)
        self.assertEqual(checked.returncode, 0, "The native QR reader must recover the exact synthetic connection.")

    def test_rejects_placeholder_and_invalid_origins_without_output(self):
        for endpoint in ["https://SET-AFTER-DEPLOYMENT.invalid", "https://example.com", "http://relay.run.app",
                         "https://secret@relay.run.app", "https://relay.run.app/path", "https://relay.run.app?secret=x",
                         "https://relay.run.app:", "https://relay.run.app:/", "https://relay.run.app:0",
                         "https://relay.run.app:65536", "https://relay.run.app:999999999999999999999", "https://relay.run.app#secret"]:
            with self.subTest(endpoint=endpoint):
                self.document["endpoint"] = endpoint
                self.save()
                self.assertNotEqual(self.invoke().returncode, 0)
                self.assertFalse(self.output.exists())

    def test_rejects_wrong_document_type_or_values(self):
        valid = dict(self.document)
        for change in [{"writeToken": "m" * 43}, {"schemaVersion": True}, {"schemaVersion": 2},
                       {"readToken": "s" * 43 + "\n"}, {"familyName": "Bad\nName"}, {"familyName": " "}]:
            with self.subTest(keys=list(change)):
                self.document = valid | change
                self.save()
                self.assertNotEqual(self.invoke().returncode, 0)
                self.assertFalse(self.output.exists())

    def test_never_overwrites_existing_file_or_output_symlink(self):
        target = self.parent / "unchanged.txt"
        target.write_text("unchanged")
        self.output.write_text("existing")
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertEqual(self.output.read_text(), "existing")
        self.output.unlink()
        self.output.symlink_to(target)
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertTrue(self.output.is_symlink())
        self.assertEqual(target.read_text(), "unchanged")

    def test_rejects_input_or_parent_symlinks_and_nonregular_input(self):
        original = self.parent / "original.json"
        self.input.rename(original)
        self.input.symlink_to(original)
        self.assertNotEqual(self.invoke().returncode, 0)
        self.input.unlink()
        original.rename(self.input)
        link = self.parent / "linked-directory"
        link.symlink_to(self.parent, target_is_directory=True)
        self.assertNotEqual(self.invoke(link / self.input.name).returncode, 0)
        self.input.unlink()
        os.mkfifo(self.input, 0o600)
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertFalse(self.output.exists())

    def test_rejects_shared_permissions_and_extended_acls(self):
        self.input.chmod(0o644)
        self.assertNotEqual(self.invoke().returncode, 0)
        self.input.chmod(0o600)
        self.parent.chmod(0o755)
        self.assertNotEqual(self.invoke().returncode, 0)
        self.parent.chmod(0o700)
        subprocess.run(["/bin/chmod", "+a", "everyone allow read", str(self.input)], check=True)
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertFalse(self.output.exists())

    def test_rejects_repository_output_and_oversized_input(self):
        with tempfile.TemporaryDirectory(prefix=".qr-test-", dir=ROOT) as directory:
            inside = Path(directory) / "parent-1.json"
            inside.write_text(json.dumps(self.document))
            inside.chmod(0o600)
            self.assertNotEqual(self.invoke(inside).returncode, 0)
            self.assertFalse(inside.with_suffix(".png").exists())
        self.input.write_bytes(b" " * 16_385)
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
