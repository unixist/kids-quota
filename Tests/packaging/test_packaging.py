"""Non-root packaging checks. All signing, launchd, and image creation calls are mocked."""
import os
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shlex
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


def function(source, name):
    return re.search(r"(?ms)^" + name + r"\(\) \{\n.*?^\}", source).group()


def executable(path, content):
    path.write_text(content)
    path.chmod(0o755)
    return path


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="kids-quota-packaging-test-")
        self.work = Path(self.temporary.name)
        self.installer = (ROOT / "scripts/install.sh").read_text()

    def tearDown(self):
        self.temporary.cleanup()

    def shell(self, body, **environment):
        script = executable(self.work / "check.sh", "#!/bin/bash\nset -euo pipefail\n" + body)
        return subprocess.run(["/bin/bash", str(script)], text=True, capture_output=True, env=dict(os.environ, **environment))

    def test_all_shell_scripts_and_launchd_plists_parse(self):
        for name in ["install.sh", "package.sh", "create-dmg.sh", "create-local-trust.sh", "build-macos.sh"]:
            subprocess.run(["/bin/bash", "-n", str(ROOT / "scripts" / name)], check=True)
        plists = re.findall(r"<<'PLIST'\n(.*?)\nPLIST", self.installer, re.S)
        self.assertEqual(len(plists), 2)
        for source in plists:
            parsed = plistlib.loads(source.encode())
            self.assertTrue(parsed["KeepAlive"])
            self.assertTrue(parsed["ProgramArguments"][0].startswith("/Library/Application Support/KidsQuota/bin/"))

    def test_parent_app_opens_for_child_login_but_cannot_be_modified(self):
        app = self.work / "Kids Quota.app"
        main = app / "Contents/MacOS/Kids Quota"
        safari = app / "Contents/PlugIns/KidsQuotaSafari.appex/Contents/MacOS/KidsQuotaSafari"
        filter_binary = app / "Contents/Library/SystemExtensions/filter.systemextension/Contents/MacOS/filter"
        helper = self.work / "bin/kids-quota-agent"
        for path in [main, safari, filter_binary, helper]:
            path.parent.mkdir(parents=True, exist_ok=True)
            executable(path, "fixture executable; never run\n")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Kids Quota"}))
        log = self.work / "ownership.log"
        chown = executable(self.work / "chown", '#!/bin/bash\nprintf "%s\\n" "$*" >> "$OWNERSHIP_LOG"\n')
        code = function(self.installer, "secure_parent_executable").replace("/usr/sbin/chown", shlex.quote(str(chown)))
        result = self.shell(code + "\nsecure_parent_executable " + shlex.quote(str(app)), OWNERSHIP_LOG=str(log))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stat.S_IMODE(main.stat().st_mode), 0o755)
        self.assertEqual(main.read_text(), "fixture executable; never run\n")
        for path in [safari, filter_binary, helper]:
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o755)
        self.assertEqual(log.read_text().strip(), "root:wheel " + str(main))
        self.assertLess(self.installer.index('secure_parent_executable "$APP_STAGE"'), self.installer.index('verify_code "$APP_STAGE"'))

    def test_parent_permission_function_rejects_executable_symlink(self):
        app = self.work / "App.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        target = executable(self.work / "unrelated", "unchanged")
        (app / "Contents/MacOS/Main").symlink_to(target)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Main"}))
        result = self.shell(function(self.installer, "secure_parent_executable") + "\nsecure_parent_executable " + shlex.quote(str(app)))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o755)

    def agent_activation(self, fail_child=False):
        log = self.work / "launch.log"
        dscl = executable(self.work / "dscl", '#!/bin/bash\nprintf "_daemon 1\\nparent 501\\nchild 502\\nloggedout 503\\nmalformed nope\\n"\n')
        launchctl = executable(self.work / "launchctl", '''#!/bin/bash
printf '%s\n' "$*" >> "$LAUNCH_LOG"
case "$*" in
  'print gui/501'|'print gui/502'|'print gui/501/com.kidsquota.agent') exit 0 ;;
  print*) exit 1 ;;
  'bootstrap gui/502 '*) [[ "$FAIL_CHILD" != 1 ]] ;;
  *) exit 0 ;;
esac
''')
        code = function(self.installer, "activate_existing_agents").replace("/usr/bin/dscl", shlex.quote(str(dscl))).replace("/bin/launchctl", shlex.quote(str(launchctl)))
        result = self.shell('AGENT="/fixture/com.kidsquota.agent.plist"\n' + code + "\nactivate_existing_agents", LAUNCH_LOG=str(log), FAIL_CHILD="1" if fail_child else "0")
        return result, log.read_text()

    def test_agents_start_only_in_confirmed_gui_sessions(self):
        result, calls = self.agent_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bootout gui/501/com.kidsquota.agent", calls)
        self.assertIn("bootstrap gui/501 /fixture/com.kidsquota.agent.plist", calls)
        self.assertIn("bootstrap gui/502 /fixture/com.kidsquota.agent.plist", calls)
        self.assertNotIn("bootstrap gui/503", calls)
        self.assertNotIn("gui/1\n", calls)
        self.assertNotIn("asuser", calls)

    def test_unavailable_gui_session_reports_restart_without_undoing_install(self):
        result, _ = self.agent_activation(fail_child=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("sign-out/sign-in or restart", result.stderr)

    def transaction(self, fail):
        bin_path = self.work / "bin"; bin_path.mkdir()
        (bin_path / "old").write_text("previous executable")
        app = self.work / "App.app"; app.mkdir()
        (app / "obsolete").write_text("resource removed in next release")
        database = self.work / "quota.sqlite"; database.write_text("keep usage")
        trust = self.work / "local-trust.json"; trust.write_text("previous trust")
        log = self.work / "launch.log"
        launchctl = executable(self.work / "launchctl", '#!/bin/bash\nprintf "%s\\n" "$*" >> "$LAUNCH_LOG"\n')
        functions = self.installer[self.installer.index("STAGING_DIRS=();"):self.installer.index("# Every replacement")]
        functions = functions.replace('/usr/sbin/chown root:wheel "$stage"', ":").replace("/bin/launchctl", shlex.quote(str(launchctl)))
        swap = self.installer[self.installer.index("for ((index=0; index<${#DESTINATIONS[@]}"):self.installer.index('/usr/bin/codesign --verify --deep --strict "$DEST_APP"')]
        body = 'DAEMON="/fixture/daemon.plist"\n' + functions
        for path in [bin_path, app]:
            body += "\nstage_destination " + shlex.quote(str(path)) + '; mkdir "$STAGED_PATH"; printf current > "$STAGED_PATH/new"\n'
        body += "\nstage_destination " + shlex.quote(str(trust)) + '; printf current-trust > "$STAGED_PATH"\n'
        body += "HAD_SERVICE=1; SERVICE_STOPPED=1\n" + swap + ("false\n" if fail else "COMMITTED=1\n")
        result = self.shell(body, LAUNCH_LOG=str(log))
        self.assertEqual(result.returncode, 1 if fail else 0, result.stderr)
        self.assertEqual(database.read_text(), "keep usage")
        self.assertEqual(trust.read_text(), "previous trust" if fail else "current-trust")
        self.assertFalse(list(self.work.glob(".kidsquota-install.*")))
        return bin_path, app, log

    def test_failed_upgrade_restores_previous_artifacts_and_service(self):
        bin_path, app, log = self.transaction(fail=True)
        self.assertEqual((bin_path / "old").read_text(), "previous executable")
        self.assertTrue((app / "obsolete").exists())
        self.assertFalse((app / "new").exists())
        self.assertIn("bootstrap system /fixture/daemon.plist", log.read_text())

    def test_successful_upgrade_removes_obsolete_bundle_files(self):
        bin_path, app, _ = self.transaction(fail=False)
        self.assertTrue((bin_path / "new").exists())
        self.assertTrue((app / "new").exists())
        self.assertFalse((app / "obsolete").exists())

    def disk_image(self, arguments, package_team="TESTTEAM00"):
        repo = self.work / "repo"
        (repo / "scripts").mkdir(parents=True)
        (repo / "dist").mkdir()
        (repo / "dist/KidsQuota-0.1.2.pkg").write_text("non-runnable package fixture")
        (repo / "dist/KidsQuota-0.1.2-Local.pkg").write_text("non-runnable local package fixture")
        capture = self.work / "image-contents"
        log = self.work / "release.log"
        pkgutil = executable(self.work / "pkgutil", '#!/bin/bash\nprintf "Developer ID Installer: Fixture (%s)\\n" "$PACKAGE_TEAM"\n')
        codesign = executable(self.work / "codesign", '#!/bin/bash\nprintf "codesign %s\\n" "$*" >> "$RELEASE_LOG"\n')
        xcrun = executable(self.work / "xcrun", '#!/bin/bash\nprintf "xcrun %s\\n" "$*" >> "$RELEASE_LOG"\n')
        hdiutil = executable(self.work / "hdiutil", '''#!/bin/bash
if [[ "$1" == create ]]; then
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == -srcfolder ]]; then cp -R "$2" "$CAPTURE"; shift 2; else output="$1"; shift; fi
  done
  printf 'non-runnable image fixture' > "$output"
fi
''')
        source = (ROOT / "scripts/create-dmg.sh").read_text()
        for original, substitute in [("/usr/sbin/pkgutil", pkgutil), ("/usr/bin/codesign", codesign), ("/usr/bin/xcrun", xcrun), ("/usr/bin/hdiutil", hdiutil)]:
            source = source.replace(original, shlex.quote(str(substitute)))
        script = executable(repo / "scripts/create-dmg.sh", source)
        env = dict(os.environ, TEAM_ID="TESTTEAM00", SIGN_IDENTITY="Developer ID Application: Test Fixture (TESTTEAM00)", NOTARY_PROFILE="fixture-not-used", PACKAGE_TEAM=package_team, CAPTURE=str(capture), RELEASE_LOG=str(log))
        result = subprocess.run(["/bin/bash", str(script)] + arguments, capture_output=True, text=True, env=env)
        return result, capture, log

    def test_preview_has_no_runnable_installer_or_application(self):
        result, contents, log = self.disk_image(["--preview"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([path.name for path in contents.iterdir()], ["Start here - PREVIEW.txt"])
        self.assertIn("contains no application or installer", (contents / "Start here - PREVIEW.txt").read_text())
        self.assertFalse(log.exists())

    def test_signed_layout_has_normal_installer_and_one_page_instructions(self):
        result, contents, log = self.disk_image([])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(path.name for path in contents.iterdir()), ["Install Kids Quota.pkg", "Start here.txt"])
        welcome = (contents / "Start here.txt").read_text()
        self.assertIn("No Terminal commands are needed", welcome)
        self.assertIn("six hours per week", welcome)
        self.assertIn("administrator", welcome)
        self.assertLess(len(welcome.splitlines()), 40)
        self.assertIn("codesign --force --timestamp", log.read_text())
        self.assertNotIn("notarytool", log.read_text())

    def test_notarization_is_explicit_and_staples_both_pkg_and_image(self):
        result, _, log = self.disk_image(["--notarize"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(log.read_text().count("notarytool submit"), 2)
        self.assertEqual(log.read_text().count("stapler validate"), 2)

    def test_wrong_team_package_is_rejected_before_image_creation(self):
        result, contents, _ = self.disk_image([], package_team="OTHERTEAM0")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(contents.exists())

    def test_local_image_contains_installer_and_explains_disabled_filter(self):
        result, contents, log = self.disk_image(["--local"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(path.name for path in contents.iterdir()), ["Install Kids Quota.pkg", "Start here.txt"])
        self.assertIn("local package fixture", (contents / "Install Kids Quota.pkg").read_text())
        welcome = (contents / "Start here.txt").read_text()
        for required in ["Open Anyway", "Load unpacked", "BrowserExtensions/Chrome", "after every Safari restart", "does NOT cut off", "inactive resource"]:
            self.assertIn(required, welcome)
        self.assertFalse(log.exists(), "Local packaging must not sign or submit to Apple")
        self.assertIn("Local.dmg", result.stdout)
        self.assertIn("Stay in the child's login", welcome)
        self.assertIn("parent's administrator username", welcome)
        self.assertNotIn("in the parent's administrator account", welcome)

    def test_local_image_rejects_notarization_and_conflicting_modes(self):
        result, contents, _ = self.disk_image(["--local", "--notarize"])
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(contents.exists())
        self.assertIn("cannot be notarized", result.stderr)

    def test_local_package_has_no_certificate_requirement_or_build_dependencies(self):
        repo = self.work / "repo"
        (repo / "scripts").mkdir(parents=True)
        (repo / "dist/local").mkdir(parents=True)
        (repo / "dist/local/local-release.json").write_text('{"fixture":true}')
        executable(repo / "scripts/install.sh", '#!/bin/bash\nprintf "%s\\n" "$*" > "$CHECK_LOG"\n')
        executable(repo / "scripts/create-local-trust.sh", '#!/bin/bash\nexit 0\n')
        captured = self.work / "package-scripts"
        pkgbuild = executable(self.work / "pkgbuild", '''#!/bin/bash
printf '%s\n' "$*" > "$PACKAGE_LOG"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --scripts ]]; then cp -R "$2" "$CAPTURE"; shift 2; else output="$1"; shift; fi
done
printf fixture > "$output"
''')
        source = (ROOT / "scripts/package.sh").read_text().replace("/usr/bin/pkgbuild", shlex.quote(str(pkgbuild)))
        script = executable(repo / "scripts/package.sh", source)
        env = {key: value for key, value in os.environ.items() if key not in ["TEAM_ID", "SIGN_IDENTITY", "INSTALLER_IDENTITY", "CHROME_EXTENSION_ID", "NOTARY_PROFILE"]}
        env.update(CAPTURE=str(captured), PACKAGE_LOG=str(self.work / "package.log"), CHECK_LOG=str(self.work / "check.log"))
        result = subprocess.run([str(script), "--local", "--pkg-only"], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--local", (self.work / "check.log").read_text())
        self.assertNotIn("--sign", (self.work / "package.log").read_text())
        self.assertIn("--auth root", (self.work / "package.log").read_text())
        self.assertTrue((repo / "dist/KidsQuota-0.1.2-Local.pkg").exists())
        self.assertTrue((captured / "create-local-trust.sh").exists())
        postinstall = (captured / "postinstall").read_text()
        self.assertIn("--local", postinstall)
        self.assertNotIn("--development", postinstall)
        self.assertNotIn("python", postinstall)

    def local_trust(self, invalid_hash=False):
        cli = self.work / "bin"
        cli.mkdir()
        app = self.work / "App.app"
        paths = [cli / ("kids-quota-" + component) for component in ["service", "agent", "bridge"]]
        paths += [app / "Contents/MacOS/Kids Quota", app / "Contents/PlugIns/KidsQuotaSafari.appex/Contents/MacOS/KidsQuotaSafari"]
        for path in paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("not executable")
        codesign = executable(self.work / "codesign", '''#!/bin/bash
if [[ "$1" == --display ]]; then
  if [[ "$BAD_HASH" == 1 ]]; then printf 'CDHash=not-a-code-hash\n'
  elif [[ "$*" == *'--arch arm64 '* ]]; then printf 'CDHash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
  else printf 'CDHash=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'; fi
fi
''')
        source = (ROOT / "scripts/create-local-trust.sh").read_text().replace("/usr/bin/codesign", shlex.quote(str(codesign)))
        script = executable(self.work / "trust.sh", source)
        return subprocess.run([str(script), str(cli), str(app)], env=dict(os.environ, BAD_HASH="1" if invalid_hash else "0"), capture_output=True, text=True)

    def test_local_trust_pins_every_component_and_both_architectures(self):
        result = self.local_trust()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(result.stdout)
        self.assertEqual(manifest["version"], 1)
        self.assertEqual([entry["role"] for entry in manifest["entries"]], ["service", "agent", "bridge", "parent", "safari"])
        for entry in manifest["entries"]:
            self.assertEqual(entry["cdhashes"], ["a" * 40, "b" * 40])
            self.assertTrue(entry["path"].startswith(("/Applications/Kids Quota.app/", "/Library/Application Support/KidsQuota/bin/")))
            self.assertNotIn(str(self.work), entry["path"])
        self.assertFalse(any(entry["role"] == "filter" for entry in manifest["entries"]))

    def test_local_trust_rejects_malformed_code_hash(self):
        result = self.local_trust(invalid_hash=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid code-directory hash", result.stderr)

    def local_check(self, wrong_key=False, activatable_filter=False):
        repo = self.work / "repo"
        scripts = repo / "scripts"; scripts.mkdir(parents=True)
        artifacts = repo / "dist/local"; artifacts.mkdir(parents=True)
        # A public-key fixture exercises the actual hash-to-Chromium-ID calculation.
        key = base64.b64encode(b"public-key-test-fixture").decode()
        extension_id = hashlib.sha256(base64.b64decode(key)).hexdigest()[:32].translate(str.maketrans("0123456789abcdef", "abcdefghijklmnop"))
        (artifacts / "local-release.json").write_text(json.dumps({"schemaVersion": 1, "networkFilterEnabled": False, "chromeExtensionId": "a" * 32 if wrong_key else extension_id}))
        chrome = artifacts / "browser/chrome"; chrome.mkdir(parents=True)
        (chrome / "manifest.json").write_text(json.dumps({"key": key}))
        resources = artifacts / "bin/kids-quota_KidsQuotaCore.bundle"; resources.mkdir(parents=True)
        (resources / "public_suffix_list.dat").write_text("com\n")
        if activatable_filter:
            (artifacts / "Kids Quota.app/Contents/Library/SystemExtensions").mkdir(parents=True)
        executable(scripts / "create-local-trust.sh", "#!/bin/bash\nexit 0\n")
        codesign = executable(self.work / "codesign", "#!/bin/bash\nprintf 'Signature=adhoc\\nflags=0x10000(runtime)\\n'\n")
        source = self.installer.replace("/usr/bin/codesign", shlex.quote(str(codesign)))
        script = executable(scripts / "install.sh", source)
        return subprocess.run([str(script), "--local", "--check", "--artifacts", str(artifacts)], capture_output=True, text=True)

    def test_local_installer_check_accepts_matching_browser_id_without_team(self):
        result = self.local_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("local signatures", result.stdout)

    def test_signature_output_is_drained_before_matching_under_pipefail(self):
        calls = self.work / "codesign.log"
        codesign = executable(self.work / "codesign", '''#!/bin/bash
set -e
printf '%s\n' "$*" >> "$CODESIGN_LOG"
if [[ "$1" == --display ]]; then
  printf 'Signature=adhoc\nflags=0x10000(runtime)\n'
  /bin/sleep 0.05
  for ((i=0; i<1000; i++)); do
    printf 'Certificate detail written after the signature and runtime lines\n'
  done
fi
''')
        code = function(self.installer, "verify_code").replace("/usr/bin/codesign", shlex.quote(str(codesign)))
        result = self.shell('MODE=local\n' + code + '\nverify_code /fixture/app com.kidsquota.app\n', CODESIGN_LOG=str(calls))
        self.assertEqual(result.returncode, 0, result.stderr)
        log = calls.read_text()
        self.assertEqual(log.count("--display"), 1)
        self.assertIn("--verify --strict --all-architectures", log)
        self.assertIn('--test-requirement =identifier "com.kidsquota.app"', log)

    def test_local_installer_rejects_mismatched_browser_id(self):
        result = self.local_check(wrong_key=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match", result.stderr)

    def test_local_installer_rejects_activatable_filter_bundle(self):
        result = self.local_check(activatable_filter=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("activatable system extension", result.stderr)


if __name__ == "__main__":
    unittest.main()
