"""Non-root packaging checks. All signing, launchd, and image creation calls are mocked."""
import os
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
        for name in ["install.sh", "package.sh", "create-dmg.sh", "build-macos.sh"]:
            subprocess.run(["/bin/bash", "-n", str(ROOT / "scripts" / name)], check=True)
        plists = re.findall(r"<<'PLIST'\n(.*?)\nPLIST", self.installer, re.S)
        self.assertEqual(len(plists), 2)
        for source in plists:
            parsed = plistlib.loads(source.encode())
            self.assertTrue(parsed["KeepAlive"])
            self.assertTrue(parsed["ProgramArguments"][0].startswith("/Library/Application Support/KidsQuota/bin/"))

    def test_only_parent_main_binary_loses_child_read_and_execute_access(self):
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
        code = function(self.installer, "restrict_parent_executable").replace("/usr/sbin/chown", shlex.quote(str(chown)))
        result = self.shell(code + "\nrestrict_parent_executable " + shlex.quote(str(app)), OWNERSHIP_LOG=str(log))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stat.S_IMODE(main.stat().st_mode), 0o750)
        self.assertEqual(main.read_text(), "fixture executable; never run\n")
        for path in [safari, filter_binary, helper]:
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o755)
        self.assertEqual(log.read_text().strip(), "root:admin " + str(main))
        self.assertLess(self.installer.index('restrict_parent_executable "$APP_STAGE"'), self.installer.index('verify_code "$APP_STAGE"'))

    def test_parent_permission_function_rejects_executable_symlink(self):
        app = self.work / "App.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        target = executable(self.work / "unrelated", "unchanged")
        (app / "Contents/MacOS/Main").symlink_to(target)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Main"}))
        result = self.shell(function(self.installer, "restrict_parent_executable") + "\nrestrict_parent_executable " + shlex.quote(str(app)))
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
        log = self.work / "launch.log"
        launchctl = executable(self.work / "launchctl", '#!/bin/bash\nprintf "%s\\n" "$*" >> "$LAUNCH_LOG"\n')
        functions = self.installer[self.installer.index("STAGING_DIRS=();"):self.installer.index("# Every replacement")]
        functions = functions.replace('/usr/sbin/chown root:wheel "$stage"', ":").replace("/bin/launchctl", shlex.quote(str(launchctl)))
        swap = self.installer[self.installer.index("for ((index=0; index<${#DESTINATIONS[@]}"):self.installer.index('/usr/bin/codesign --verify --deep --strict "$DEST_APP"')]
        body = 'DAEMON="/fixture/daemon.plist"\n' + functions
        for path in [bin_path, app]:
            body += "\nstage_destination " + shlex.quote(str(path)) + '; mkdir "$STAGED_PATH"; printf current > "$STAGED_PATH/new"\n'
        body += "HAD_SERVICE=1; SERVICE_STOPPED=1\n" + swap + ("false\n" if fail else "COMMITTED=1\n")
        result = self.shell(body, LAUNCH_LOG=str(log))
        self.assertEqual(result.returncode, 1 if fail else 0, result.stderr)
        self.assertEqual(database.read_text(), "keep usage")
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
        (repo / "dist/KidsQuota-0.1.0.pkg").write_text("non-runnable package fixture")
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


if __name__ == "__main__":
    unittest.main()
