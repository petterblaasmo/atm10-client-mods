#!/usr/bin/env python3
"""Publish the client mod overlay for the ATM10 server as a GitHub release.

Players' updater reads releases/latest/download/manifest.json. Own mods are uploaded as
release assets; mods found on Modrinth (by SHA-1) are linked to Modrinth's CDN instead,
so third-party jars are never redistributed.
"""
import argparse
import fnmatch
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

MANIFEST_SCHEMA = 1
MODRINTH_VERSION_FILE = "https://api.modrinth.com/v2/version_file/{sha1}?algorithm=sha1"
CFWIDGET_PROJECT = "https://api.cfwidget.com/minecraft/mc-mods/{slug}"
CURSEFORGE_DOWNLOAD = "https://www.curseforge.com/api/v1/mods/{project}/files/{file}/download"
USER_AGENT = "atm10-client-publisher/1.0"


def load_config(path):
    config = json.loads(Path(path).read_text(encoding="utf-8"))
    for key in ("repo", "serverDir", "include"):
        if key not in config:
            sys.exit(f"config is missing '{key}'")
    return config


def hash_file(path):
    sha1, sha256 = hashlib.sha1(), hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            sha1.update(chunk)
            sha256.update(chunk)
    return sha1.hexdigest(), sha256.hexdigest()


def select_jars(mods_dir, includes):
    """Resolve include entries ("pattern" or {"pattern", "curseforge"}) to (jar, pattern, curseforge_slug)."""
    jars = sorted(p for p in Path(mods_dir).glob("*.jar") if p.is_file())
    selected = []
    for include in includes:
        pattern, slug = (include, None) if isinstance(include, str) else (include["pattern"], include.get("curseforge"))
        matches = [jar for jar in jars if fnmatch.fnmatch(jar.name, pattern)]
        if not matches:
            sys.exit(f"pattern '{pattern}' matches no jar in {mods_dir}")
        if len(matches) > 1:
            sys.exit(f"pattern '{pattern}' is ambiguous: {[m.name for m in matches]}")
        selected.append((matches[0], pattern, slug))
    return selected


def fetch_json(url):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def curseforge_url(slug, filename):
    project = fetch_json(CFWIDGET_PROJECT.format(slug=slug))
    for file in project.get("files", []):
        if file.get("name") == filename:
            return CURSEFORGE_DOWNLOAD.format(project=project["id"], file=file["id"])
    sys.exit(f"CurseForge project '{slug}' has no file named {filename}; refusing to re-host it")


def modrinth_url(sha1, filename):
    try:
        version = fetch_json(MODRINTH_VERSION_FILE.format(sha1=sha1))
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise
    for file in version.get("files", []):
        if file.get("hashes", {}).get("sha1") == sha1:
            return file["url"]
    print(f"warning: Modrinth matched {filename} but no file with its hash", file=sys.stderr)
    return None


def updater_entry(config, tag, updater_path):
    if not updater_path:
        return None
    _, sha256 = hash_file(updater_path)
    name = Path(updater_path).name
    return {"url": f"https://github.com/{config['repo']}/releases/download/{tag}/{name}", "sha256": sha256}


def build_manifest(config, tag, updater_path=None, mac_updater_path=None):
    entries, uploads = [], []
    for jar, pattern, curseforge_slug in select_jars(Path(config["serverDir"]) / "mods", config["include"]):
        sha1, sha256 = hash_file(jar)
        url = curseforge_url(curseforge_slug, jar.name) if curseforge_slug else modrinth_url(sha1, jar.name)
        if url is None:
            url = f"https://github.com/{config['repo']}/releases/download/{tag}/{jar.name}"
            uploads.append(jar)
        entries.append({
            "path": f"mods/{jar.name}",
            "sha256": sha256,
            "size": jar.stat().st_size,
            "url": url,
            "replaces": pattern,
        })
    manifest = {
        "schema": MANIFEST_SCHEMA,
        "version": tag,
        "minecraft": config.get("minecraft", "1.21.1"),
        "pack": config.get("pack", ""),
        "files": entries,
    }
    for key, path in (("updater", updater_path), ("macUpdater", mac_updater_path)):
        entry = updater_entry(config, tag, path)
        if entry:
            manifest[key] = entry
    return manifest, uploads


def previous_manifest(repo):
    result = subprocess.run(
        ["gh", "release", "download", "--repo", repo, "--pattern", "manifest.json", "--output", "-"],
        capture_output=True, text=True,
    )
    return json.loads(result.stdout) if result.returncode == 0 and result.stdout.strip() else None


def same_files(a, b):
    files = lambda m: sorted((f["path"], f["sha256"]) for f in m["files"])
    updaters = lambda m: [(m.get(key) or {}).get("sha256") for key in ("updater", "macUpdater")]
    return a is not None and files(a) == files(b) and updaters(a) == updaters(b)


def publish(config, manifest, uploads, updater_paths):
    with tempfile.TemporaryDirectory() as tmp:
        manifest_path = Path(tmp) / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        assets = [str(manifest_path), *map(str, uploads)]
        assets += [path for path in updater_paths if path]
        changes = "\n".join(f"- {Path(f['path']).name}" for f in manifest["files"])
        subprocess.run(
            ["gh", "release", "create", manifest["version"], "--repo", config["repo"], "--latest",
             "--title", f"Client mods {manifest['version']}", "--notes", f"Client mod overlay:\n{changes}", *assets],
            check=True,
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=str(Path(__file__).with_name("client-mods.json")))
    parser.add_argument("--updater", help="ATM10-Updater.cmd to attach to the release")
    parser.add_argument("--mac-updater", help="atm10-updater.sh to attach to the release")
    parser.add_argument("--dry-run", action="store_true", help="print the manifest without publishing")
    parser.add_argument("--force", action="store_true", help="publish even if nothing changed")
    args = parser.parse_args()

    config = load_config(args.config)
    tag = time.strftime("v%Y.%m.%d-%H%M%S", time.gmtime())
    manifest, uploads = build_manifest(config, tag, args.updater, args.mac_updater)
    print(json.dumps(manifest, indent=2))
    print(f"uploading {len(uploads)} own jar(s): {[u.name for u in uploads]}", file=sys.stderr)
    if args.dry_run:
        return
    if shutil.which("gh") is None:
        sys.exit("gh CLI not found")
    if not args.force and same_files(previous_manifest(config["repo"]), manifest):
        print("no changes since the latest release; nothing published", file=sys.stderr)
        return
    publish(config, manifest, uploads, [args.updater, args.mac_updater])
    print(f"published {tag}", file=sys.stderr)


if __name__ == "__main__":
    main()
