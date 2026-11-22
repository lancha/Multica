#!/usr/bin/env python3
"""Offline controller integration tests; no package installs or real agents."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("build-desktop-macos.sh").resolve()


class BuilderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="multica-builder-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / "checkout"
        self.repo.mkdir()
        self.env = {key: value for key, value in os.environ.items()
                    if key in ("PATH", "LANG", "SYSTEMROOT")}
        self.env.update({"HOME": str(self.root / "home"), "TMPDIR": str(self.root / "tmp"),
                         "WORK_DIR": str(self.repo), "TARGET_ARCH": "arm64",
                         "FORGEJO_BASE_URL": "https://forgejo.example", "FORGEJO_TOKEN": "test-only",
                         "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"})
        Path(self.env["TMPDIR"]).mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        (self.repo / ".gitignore").write_text("dist/\n")
        self.git("add", ".gitignore")
        self.git("commit", "-qm", "release without cleanup helper")
        self.git("tag", "v0.6.2")
        self.git("tag", "deploy/v0.6.2")
        helper = self.repo / "scripts/selfhost/cleanup-desktop-artifacts.py"
        helper.parent.mkdir(parents=True)
        helper.write_text('''import json, os, sys
release = json.load(sys.stdin)
assert release["tag_name"] == "v0.6.2"
assert os.environ["FORGEJO_TOKEN"] == "test-only"
print("STUB_CLEANUP " + ("dry-run" if "--dry-run" in sys.argv else "execute"))
sys.exit(int(os.environ.get("TEST_CLEANUP_FAIL", "0")))
''')
        self.git("add", "scripts")
        self.git("commit", "-qm", "controller helper")
        bare = self.root / "origin.git"
        subprocess.run(["git", "clone", "-q", "--bare", str(self.repo), str(bare)], check=True, env=self.env)
        self.git("remote", "add", "origin", str(bare))
        names = [f"multica-desktop-0.6.2-mac-arm64{suffix}"
                 for suffix in (".dmg", ".zip", ".dmg.blockmap", ".zip.blockmap")] + ["latest-mac.yml"]
        self.release = {"id": 1, "tag_name": "v0.6.2", "draft": False, "prerelease": False,
                        "assets": [{"name": name, "size": 1} for name in names]}
        dist = self.repo / "apps/desktop/dist"
        dist.mkdir(parents=True)
        for name in names:
            (dist / name).write_text("x")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        fake_curl = bin_dir / "curl"
        fake_curl.write_text(f'''#!{shutil.which("python3")}
import json, os, sys
from pathlib import Path
release = json.loads(Path(os.environ["TEST_RELEASE"]).read_text())
if "POST" in sys.argv:
    print("UPLOAD " + next(arg for arg in sys.argv if arg.startswith("attachment=@")), file=sys.stderr)
    sys.exit(int(os.environ.get("TEST_UPLOAD_FAIL", "0")))
if any("/releases?" in arg for arg in sys.argv):
    if os.environ.get("TEST_MISSING_ASSETS"):
        release["assets"] = []
    print(json.dumps([release]))
else:
    print(json.dumps(release))
''')
        fake_curl.chmod(0o755)
        for name in ("pnpm", "go", "xcode-select"):
            path = bin_dir / name
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        release_path = self.root / "release.json"
        release_path.write_text(json.dumps(self.release))
        self.env["TEST_RELEASE"] = str(release_path)
        self.env["PATH"] = str(bin_dir) + os.pathsep + os.environ["PATH"]

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], env=self.env, text=True).strip()

    def run_builder(self, **options):
        env = dict(self.env, **options)
        result = subprocess.run(["/bin/bash", str(SCRIPT)], env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        self.assertEqual(self.git("branch", "--show-current"), options.get("WORK_BRANCH", "main"))
        self.assertFalse((Path(self.env["TMPDIR"]) / "multica-desktop-builder.lock").exists())
        return result

    def test_already_published_runs_cleanup_without_upload(self):
        result = self.run_builder()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("STUB_CLEANUP execute", result.stdout)
        self.assertNotIn("UPLOAD ", result.stdout)
        self.assertIn("PROGRESS v0.6.2 100", result.stdout)

    def test_opt_out_skips_cleanup(self):
        result = self.run_builder(CLEANUP_AFTER_UPLOAD="0")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("STUB_CLEANUP", result.stdout)

    def test_dry_run_propagates_to_cleanup(self):
        result = self.run_builder(DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("STUB_CLEANUP dry-run", result.stdout)
        self.assertNotIn("PROGRESS v0.6.2 100", result.stdout)

    def test_housekeeping_failure_does_not_reopen_completed_issue(self):
        result = self.run_builder(TEST_CLEANUP_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("PROGRESS v0.6.2 FAILED", result.stdout)
        self.assertNotIn("PROGRESS v0.6.2 100", result.stdout)

    def test_old_tag_uses_snapshot_after_successful_upload(self):
        result = self.run_builder(TEST_MISSING_ASSETS="1")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout.count("UPLOAD "), 5)
        self.assertLess(result.stdout.index("PROGRESS v0.6.2 90"), result.stdout.index("STUB_CLEANUP"))
        self.assertLess(result.stdout.index("STUB_CLEANUP"), result.stdout.index("PROGRESS v0.6.2 100"))

    def test_failed_upload_never_runs_cleanup(self):
        result = self.run_builder(TEST_MISSING_ASSETS="1", TEST_UPLOAD_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("STUB_CLEANUP", result.stdout)
        self.assertNotIn("PROGRESS v0.6.2 100", result.stdout)

    def test_new_publication_cleanup_failure_does_not_report_completion(self):
        result = self.run_builder(TEST_MISSING_ASSETS="1", TEST_CLEANUP_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PROGRESS v0.6.2 FAILED", result.stdout)
        self.assertNotIn("PROGRESS v0.6.2 100", result.stdout)

    def test_localized_four_component_release_is_never_packaged(self):
        # A localized X.Y.Z.N release is server-only: its four-component version
        # is not valid semver, so electron-updater would refuse to start in the
        # built app. The builder must keep targeting the newest plain release.
        self.git("tag", "v0.6.3.1")
        self.git("tag", "deploy/v0.6.3.1")
        result = self.run_builder()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("target tag: v0.6.2 (version 0.6.2,", result.stdout)
        self.assertNotIn("v0.6.3.1", result.stdout)

    def test_localized_release_alone_yields_no_packageable_tag(self):
        for repo in (self.repo, self.root / "origin.git"):
            subprocess.run(["git", "-C", str(repo), "tag", "-d", "v0.6.2", "deploy/v0.6.2"],
                           check=True, env=self.env, stdout=subprocess.DEVNULL)
        self.git("tag", "v0.6.3.1")
        self.git("tag", "deploy/v0.6.3.1")
        result = self.run_builder()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no tag matching", result.stdout)


if __name__ == "__main__":
    unittest.main()
