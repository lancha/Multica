#!/usr/bin/env python3
"""Verify published copies before deleting allowlisted, ignored build outputs."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("release download redirects are not allowed")


def artifact_names(tag, arch):
    if not re.fullmatch(r"v\d+\.\d+\.\d+(?:-mikeux\.\d+)?", tag):
        raise ValueError("invalid release tag")
    if arch not in ("arm64", "x64"):
        raise ValueError("unsupported architecture")
    prefix = f"multica-desktop-{tag[1:]}-mac-{arch}"
    return [prefix + suffix for suffix in (".dmg", ".zip", ".dmg.blockmap", ".zip.blockmap")] + ["latest-mac.yml"]


def trusted_url(raw, base, repo, tag, name):
    origin = urllib.parse.urlsplit(base)
    url = urllib.parse.urlsplit(raw)
    expected = origin.path.rstrip("/") + f"/{repo}/releases/download/{tag}/{name}"
    if (origin.scheme != "https" or not origin.netloc or origin.username or origin.password
            or origin.query or origin.fragment or not re.fullmatch(r"[\w.-]+/[\w.-]+", repo)
            or url.scheme != origin.scheme or url.netloc != origin.netloc
            or url.username or url.password or url.path != expected or url.query or url.fragment):
        raise ValueError("untrusted release download URL")
    return raw


def digest_stream(stream, limit, deadline=None):
    digest = hashlib.sha256()
    size = 0
    while True:
        if deadline is not None and time.monotonic() > deadline:
            raise ValueError("artifact verification deadline exceeded")
        chunk = stream.read(1024 * 1024)
        if not chunk:
            break
        size += len(chunk)
        if size > limit:
            raise ValueError("artifact exceeds declared size")
        digest.update(chunk)
    if size != limit:
        raise ValueError("artifact size mismatch")
    return digest.hexdigest()


def remote_digest(url, token, size):
    headers = {"Accept-Encoding": "identity"}
    if token:
        headers["Authorization"] = "token " + token
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.build_opener(NoRedirect).open(request, timeout=60) as response:
        if response.status != 200 or "text/html" in response.headers.get("Content-Type", "").lower():
            raise ValueError("invalid release download response")
        return digest_stream(response, size, time.monotonic() + 1800)


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def cleanup_outputs(work_dir, tag, arch, release, base, repo, token="", dry_run=False,
                    downloader=remote_digest):
    names = artifact_names(tag, arch)
    root = Path(work_dir).resolve(strict=True)
    if root in (Path(root.anchor), Path.home().resolve()):
        raise ValueError("refusing broad cleanup root")
    if Path(git(root, "rev-parse", "--show-toplevel")).resolve() != root:
        raise ValueError("cleanup root is not the checkout root")
    if (release.get("tag_name") != tag or release.get("draft") is not False
            or release.get("prerelease") is not False):
        raise ValueError("release is not the expected published stable tag")
    assets = release.get("assets", [])
    selected = {}
    for name in names:
        matches = [a for a in assets if a.get("name") == name]
        if len(matches) != 1 or type(matches[0].get("size")) is not int or matches[0]["size"] <= 0:
            raise ValueError("published artifact missing, empty, or ambiguous: " + name)
        selected[name] = matches[0]
        trusted_url(matches[0]["browser_download_url"], base, repo, tag, name)

    # Dist is removed last so earlier cleanup failures leave verification files.
    goarch = "arm64" if arch == "arm64" else "amd64"
    relative_targets = [
        "apps/desktop/out",
        "apps/desktop/resources/bin/multica",
        f"server/bin/darwin-{goarch}/multica",
        "apps/desktop/dist",
    ]
    targets = []
    for relative in relative_targets:
        target = root / relative
        cursor = root
        for component in Path(relative).parts:
            cursor /= component
            if cursor.is_symlink() or os.path.ismount(cursor):
                raise ValueError("refusing symlink or mounted cleanup target: " + relative)
        if not target.exists():
            continue
        if git(root, "ls-files", "--", relative):
            raise ValueError("refusing tracked cleanup target: " + relative)
        ignored = subprocess.run(["git", "-C", str(root), "check-ignore", "-q", "--", relative])
        if ignored.returncode != 0:
            raise ValueError("cleanup target must be Git-ignored: " + relative)
        if target.is_dir():
            for current, directories, _ in os.walk(target, followlinks=False):
                if any(os.path.ismount(Path(current) / child) for child in directories):
                    raise ValueError("refusing nested mounted cleanup target: " + relative)
        targets.append(target)
    if not targets:
        print("CLEANUP no generated outputs remain", flush=True)
        return []

    dist = root / "apps/desktop/dist"
    allowed = set(names) | {"mac-arm64" if arch == "arm64" else "mac", "builder-debug.yml", "builder-effective-config.yaml", ".DS_Store"}
    if not dist.is_dir() or any(entry.name not in allowed for entry in dist.iterdir()):
        raise ValueError("dist is missing or contains output from another release/architecture")
    local_hashes = {}
    for name in names:
        path = dist / name
        if path.is_symlink() or not path.is_file():
            raise ValueError("local release artifact missing or linked: " + name)
        with path.open("rb") as stream:
            local_hashes[name] = digest_stream(stream, selected[name]["size"])
    if dry_run:
        for target in targets:
            print("DRY_RUN verify remote SHA-256, then remove " + str(target), flush=True)
        return []

    # Complete every read-only verification before removing anything. Network
    # failures, wrong bytes, redirects, or changed local files preserve output.
    for name in names:
        asset = selected[name]
        if downloader(asset["browser_download_url"], token, asset["size"]) != local_hashes[name]:
            raise ValueError("published SHA-256 mismatch: " + name)
        print("CLEANUP verified remote SHA-256: " + name, flush=True)
    for name in names:
        if (dist / name).is_symlink():
            raise ValueError("local artifact changed during verification")
        with (dist / name).open("rb") as stream:
            if digest_stream(stream, selected[name]["size"]) != local_hashes[name]:
                raise ValueError("local artifact changed during verification")
    removed = []
    for target in targets:
        if target.is_symlink() or os.path.ismount(target):
            raise ValueError("cleanup target changed during verification")
        if target.is_dir():
            shutil.rmtree(target)
        else:
            target.unlink()
        removed.append(str(target))
        print("CLEANUP removed generated output: " + str(target), flush=True)
    return removed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--arch", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        cleanup_outputs(args.work_dir, args.tag, args.arch, json.load(sys.stdin),
                        args.base, args.repo, os.environ.get("FORGEJO_TOKEN", ""), args.dry_run)
    except Exception:
        # Network exceptions may embed request details. Do not print credentials
        # or claim output is retained if a filesystem error interrupted removal.
        print("CLEANUP failed; verification or guarded deletion did not finish. Inspect local outputs before retrying.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
