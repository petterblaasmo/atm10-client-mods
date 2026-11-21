# AGENTS.md

Instructions for AI agents working on this repo. Read fully before changing anything.

## What this is

Players use the **CurseForge app** with the official **All the Mods 10** pack. Our server runs extra mods on top of it. This repo ships those extra client mods:

| Part | Runs on | Role |
|---|---|---|
| `updater/ATM10-Updater.cmd` | Players' Windows PCs | One double-click: finds the ATM10 instance, syncs extra mods from the latest release manifest |
| `publisher/publish.py` | The game server | Builds `manifest.json` from server jars and creates a GitHub release |
| `publisher/client-mods.json` | The game server | Which server jars players need, and where each is downloaded from |

Players fetch `https://github.com/petterblaasmo/atm10-client-mods/releases/latest/download/manifest.json`. The release marked **Latest** is what every player gets, so a release is a production deploy.

## Server facts

- SSH host alias `atm10` (Ubuntu, Tailscale). Agents in T3 Code may have it as a linked environment.
- Minecraft server: `/opt/minecraft/atm10` (NeoForge 1.21.1), jars in `mods/`, owned by user `minecraft`. User `petter` can read them, no sudo needed.
- This repo is cloned at `~/atm10-client-updater` on the server. `gh` there is authenticated with a fine-grained token limited to this repo (Contents: read/write). Never print, copy or replace that token; if it expired, ask the owner for a new one.

## Publishing an update (the common task)

```bash
ssh atm10
cd ~/atm10-client-updater && git pull -q && cd publisher
python3 publish.py --dry-run                                  # review the manifest first
python3 publish.py --updater ../updater/ATM10-Updater.cmd     # publish
```

- The script exits without publishing when nothing changed; `--force` overrides that.
- Always attach `--updater` so the latest release keeps the player download link working.
- Tell the owner the new tag. Players must close the game and run the updater.

## Adding or removing a client mod

1. Decide if players need it. Content mods (new blocks, items, entities, registries) and client tweaks: yes. Server-only mods (Chunky, BlueMap, `atm10-blocklog`, `atm10-perf`): no.
2. Edit `include` in `publisher/client-mods.json`. Use a version wildcard (`name-*.jar`) so updates are picked up; the pattern must match exactly one jar. It also becomes the updater's `replaces` pattern, which deletes old versions on players' PCs, so keep it specific to that mod.
3. Pick the download source, in this order:
   - On Modrinth: nothing to do, matched automatically by SHA-1.
   - Third-party on CurseForge: `{ "pattern": "x-*.jar", "curseforge": "<slug>" }`.
   - Our own mods, or licenses that allow redistribution (MIT, Apache, LGPL...): uploaded to the release automatically.
4. **Licensing rule:** never re-host a third-party jar marked "All Rights Reserved" or without a license. Check `license` in its `META-INF/neoforge.mods.toml`. If it is not on Modrinth or CurseForge, stop and ask the owner.
5. Commit, push, `git pull` on the server, dry-run, publish.

## Changing the updater

Keep these invariants; each one prevents breaking players' installs:

- Only delete files the updater installed (tracked in `mods/.atm10-updater-state.json`) or files matching an entry's `replaces` pattern. Never touch the rest of the pack.
- Validate every manifest field before use: paths must match `^mods/<safe name>.jar$`, URLs must be HTTPS, `replaces` must be a safe single-wildcard pattern.
- Download to a temp file, verify sha256, then move into place. A failed download must leave no partial jar.
- Refuse to run while Minecraft runs from that instance.
- Must work on stock **Windows PowerShell 5.1**: no `??`, `?.`, ternaries or `&&`; use `-UseBasicParsing`.
- The file must keep **CRLF** line endings (`.gitattributes` enforces it); the first lines are a batch/PowerShell polyglot.
- Changing the manifest format means bumping `schema` in both files. Old updaters then tell players to download the new one, so publish with `--updater` in the same release.

## Testing the updater

Test against a fake instance; never against a real player install:

```powershell
$T = "$env:TEMP\atm10-test"
New-Item -ItemType Directory "$T\inst\mods" -Force | Out-Null
'{}' | Set-Content "$T\inst\minecraftinstance.json"
$env:ATM10_INSTANCE = "$T\inst"
$env:ATM10_MANIFEST_URL = "file:///$($T -replace '\\','/')/manifest.json"   # omit to use the live release
"`n" | cmd /c updater\ATM10-Updater.cmd; "exit=$LASTEXITCODE"
```

Also test auto-discovery without `ATM10_INSTANCE`: point `$env:USERPROFILE` and `$env:APPDATA` at a temp folder containing `curseforge\minecraft\Instances\All the Mods 10\` with exactly one instance, then with two. PowerShell unrolls one-element arrays returned from functions; wrap such calls in `@(...)`.

Cover at least: fresh install, a second run that changes nothing, an old version replaced, a stale managed file removed, an unrelated jar kept, a checksum mismatch (exit 1, no file left), an unsafe path refused (exit 1).

## Conventions

- Conventional commits: `<type>(<scope>): <subject>`, imperative, ≤ 50 chars, no AI attribution lines.
- English only. Keep the code minimal and self-documenting.
- Ask the owner before deleting releases or making the repo private; players depend on the `latest` links.
