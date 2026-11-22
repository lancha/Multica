#!/usr/bin/env python3
"""Offline safety regressions for release-output cleanup."""

import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "cleanup", Path(__file__).with_name("cleanup-desktop-artifacts.py"))
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="multica-cleanup-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / ".gitignore").write_text("dist/\nout/\nbin/\nnode_modules/\n")
        self.names = cleanup.artifact_names("v0.6.2", "arm64")
        self.dist = self.root / "apps/desktop/dist"
        self.dist.mkdir(parents=True)
        self.contents = {name: (name + "\n").encode() for name in self.names}
        for name, content in self.contents.items():
            (self.dist / name).write_bytes(content)
        self.kept = ["source.txt", ".env", "node_modules/keep", "server/bin/linux-arm64/multica"]
        self.generated = ["apps/desktop/out/main.js", "apps/desktop/resources/bin/multica",
                          "server/bin/darwin-arm64/multica", "apps/desktop/dist/mac-arm64/Multica.app/main"]
        for relative in self.kept + self.generated:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("test fixture")
        self.base = "https://forgejo.example:188"
        self.release = {
            "tag_name": "v0.6.2", "draft": False, "prerelease": False,
            "assets": [{"name": name, "size": len(content), "browser_download_url":
                        f"{self.base}/mike/Multica/releases/download/v0.6.2/{name}"}
                       for name, content in self.contents.items()],
        }
        self.downloads = []

    def download(self, url, token, size):
        name = url.rsplit("/", 1)[1]
        self.downloads.append(name)
        return cleanup.digest_stream(io.BytesIO(self.contents[name]), size)

    def run_cleanup(self, **options):
        args = dict(work_dir=self.root, tag="v0.6.2", arch="arm64", release=self.release,
                    base=self.base, repo="mike/Multica", downloader=self.download)
        args.update(options)
        with patch("sys.stdout", new_callable=io.StringIO):
            return cleanup.cleanup_outputs(**args)

    def assert_retained(self):
        for relative in self.kept + self.generated:
            self.assertTrue((self.root / relative).exists(), relative)

    def test_success_preserves_source_dependencies_credentials_other_platforms(self):
        # Electron frameworks contain symlinks. Remove the link, not its target.
        (self.dist / "mac-arm64/Multica.app/link").symlink_to(self.root / "source.txt")
        self.assertEqual(len(self.run_cleanup()), 4)
        self.assertEqual(self.downloads, self.names)
        for relative in self.kept:
            self.assertTrue((self.root / relative).exists())
        for relative in self.generated:
            self.assertFalse((self.root / relative).exists())
        self.downloads.clear()
        self.assertEqual(self.run_cleanup(), [])
        self.assertEqual(self.downloads, [])

    def test_dry_run_never_downloads_or_deletes(self):
        self.assertEqual(self.run_cleanup(dry_run=True), [])
        self.assertEqual(self.downloads, [])
        self.assert_retained()

    def test_missing_ambiguous_empty_size_or_unpublished_release_preserves_all(self):
        variants = []
        for key, value in [("draft", True), ("prerelease", True), ("tag_name", "v0.6.1")]:
            release = copy.deepcopy(self.release)
            release[key] = value
            variants.append(release)
        release = copy.deepcopy(self.release)
        release["assets"].pop()
        variants.append(release)
        release = copy.deepcopy(self.release)
        release["assets"].append(release["assets"][0])
        variants.append(release)
        for size in [0, True, "20", 1, 100000]:
            release = copy.deepcopy(self.release)
            release["assets"][0]["size"] = size
            variants.append(release)
        for release in variants:
            with self.subTest(release=release):
                with self.assertRaises(ValueError):
                    self.run_cleanup(release=release)
                self.assert_retained()

    def test_wrong_hash_or_download_failure_preserves_all(self):
        def fail(*args):
            raise OSError("simulated failure")
        for downloader in [lambda *args: "bad-hash", fail]:
            with self.assertRaises((ValueError, OSError)):
                self.run_cleanup(downloader=downloader)
            self.assert_retained()

    def test_untrusted_download_urls_preserve_all(self):
        original = self.release["assets"][0]["browser_download_url"]
        for url in [original.replace("https:", "http:"), original.replace("forgejo.example", "evil.example"),
                    original.replace("v0.6.2", "v0.6.1"), original + "?secret=x", original + "#fragment",
                    original.replace("https://", "https://user:password@")]:
            with self.subTest(url=url):
                release = copy.deepcopy(self.release)
                release["assets"][0]["browser_download_url"] = url
                with self.assertRaises(ValueError):
                    self.run_cleanup(release=release)
                self.assert_retained()

    def test_redirects_and_invalid_network_responses_are_rejected(self):
        with self.assertRaises(ValueError):
            cleanup.NoRedirect().redirect_request(None, None, 302, "", {}, "https://evil.example")
        for status, content_type in [(206, "application/octet-stream"), (200, "text/html")]:
            with patch.object(cleanup.urllib.request, "build_opener") as opener:
                response = opener.return_value.open.return_value.__enter__.return_value
                response.status = status
                response.headers = {"Content-Type": content_type}
                with self.assertRaises(ValueError):
                    cleanup.remote_digest("https://forgejo.example", "", 10)

    def test_local_change_during_verification_preserves_all(self):
        def change(url, token, size):
            result = self.download(url, token, size)
            (self.dist / self.names[0]).write_bytes(b"x" * len(self.contents[self.names[0]]))
            return result
        with self.assertRaises(ValueError):
            self.run_cleanup(downloader=change)
        self.assert_retained()

    def test_tracked_output_is_never_removed(self):
        subprocess.run(["git", "-C", str(self.root), "add", "-f", self.generated[0]], check=True)
        with self.assertRaises(ValueError):
            self.run_cleanup()
        self.assert_retained()

    def test_unknown_release_output_is_retained(self):
        (self.dist / "multica-desktop-0.6.3-mac-arm64.zip").write_text("unpublished")
        with self.assertRaises(ValueError):
            self.run_cleanup()
        self.assert_retained()

    def test_linked_target_is_never_followed(self):
        out = self.root / "apps/desktop/out"
        out.rename(out.with_name("saved-out"))
        out.symlink_to(out.with_name("saved-out"), target_is_directory=True)
        with self.assertRaises(ValueError):
            self.run_cleanup()
        self.assert_retained()

    def test_nonignored_target_is_retained(self):
        (self.root / ".gitignore").write_text("dist/\nbin/\n")
        with self.assertRaises(ValueError):
            self.run_cleanup()
        self.assert_retained()

    def test_nested_mount_is_retained(self):
        nested = self.dist / "mac-arm64"
        with patch.object(cleanup.os.path, "ismount", side_effect=lambda p: Path(p) == nested):
            with self.assertRaises(ValueError):
                self.run_cleanup()
        self.assert_retained()

    def test_stream_size_and_deadline_are_bounded(self):
        for content, size in [(b"abc", 2), (b"a", 2)]:
            with self.assertRaises(ValueError):
                cleanup.digest_stream(io.BytesIO(content), size)
        with self.assertRaises(ValueError):
            cleanup.digest_stream(io.BytesIO(b"abc"), 3, deadline=0)


if __name__ == "__main__":
    unittest.main()
