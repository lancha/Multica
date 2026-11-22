import base64
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def digest(path, algorithm):
    result = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result


def main():
    tag = os.environ["RELEASE_TAG"]
    source = os.environ["SOURCE_REVISION"]
    if not re.fullmatch(r"v\d+\.\d+\.\d+(?:-mikeux\.\d+)?", tag):
        raise ValueError("Invalid release tag")
    metadata = json.loads(Path(".github/homelab-source.json").read_text())
    if not re.fullmatch(r"[0-9a-f]{40}", source) or metadata["revision"] != source:
        raise ValueError("Forgejo source does not match the requested commit")
    version = tag[1:]
    package = json.loads(Path("apps/desktop/package.json").read_text())
    if package["version"] != version.split("-")[0]:
        raise ValueError("Package version does not match the promoted release")
    if sys.argv[1] == "prepare":
        subprocess.run(["git", "tag", tag], check=True)
        return
    if sys.argv[1] != "verify":
        raise ValueError("Expected prepare or verify")
    dist = Path("apps/desktop/dist")
    names = [f"multica-desktop-{version}-mac-arm64.{extension}" for extension in ("dmg", "zip")]
    names += [f"{name}.blockmap" for name in names]
    names += ["latest-mac.yml"]
    for name in names:
        if not (dist / name).is_file() or not (dist / name).stat().st_size:
            raise ValueError(f"Missing asset: {name}")
    feed = (dist / "latest-mac.yml").read_text()
    if not re.search(rf"^version: ['\"]?{re.escape(version)}['\"]?$", feed, re.MULTILINE):
        raise ValueError("Update feed version mismatch")
    for name in names[:2]:
        expected = base64.b64encode(digest(dist / name, "sha512").digest()).decode()
        if not re.search(rf"- url: {re.escape(name)}\n\s+sha512: {re.escape(expected)}\n\s+size: {(dist / name).stat().st_size}(?:\n|$)", feed):
            raise ValueError(f"Update feed hash or size mismatch: {name}")
    subprocess.run(["hdiutil", "verify", str(dist / names[0])], check=True)
    with tempfile.TemporaryDirectory(prefix="multica-verify-") as temporary:
        subprocess.run(["ditto", "-xk", str(dist / names[1]), temporary], check=True)
        app = Path(temporary) / "Multica.app"
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if info["CFBundleShortVersionString"] != version:
            raise ValueError("App bundle version mismatch")
        executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
        arch = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).strip()
        if arch != "arm64":
            raise ValueError(f"Unexpected architecture: {arch}")
        update = (app / "Contents/Resources/app-update.yml").read_text()
        if "provider: generic" not in update or os.environ["MULTICA_UPDATE_URL"] not in update:
            raise ValueError("App updater configuration mismatch")
    manifest = {
        "schema": 1,
        "release_tag": tag,
        "source_revision": source,
        "github_sha": os.environ["GITHUB_SHA"],
        "run_id": int(os.environ["GITHUB_RUN_ID"]),
        "run_attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
        "architecture": "arm64",
        "update_url": os.environ["MULTICA_UPDATE_URL"],
        "files": {
            name: {
                "size": (dist / name).stat().st_size,
                "sha256": digest(dist / name, "sha256").hexdigest(),
                "sha512": base64.b64encode(digest(dist / name, "sha512").digest()).decode(),
            }
            for name in names
        },
    }
    (dist / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
