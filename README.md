# ATM10 client mods

Extra client mods for our All the Mods 10 server, on top of the CurseForge pack.

## Players

1. Download **[ATM10-Updater.cmd](https://github.com/petterblaasmo/atm10-client-mods/releases/latest/download/ATM10-Updater.cmd)** once.
2. Close Minecraft and double-click it whenever the server announces an update, then press Play in CurseForge.

The updater finds your ATM10 instance, installs or updates the server's extra mods, verifies every download, and removes old versions it installed. It never touches the rest of your pack.

If Windows SmartScreen warns about the file, choose **More info → Run anyway**.

## Admins

On the server, after changing mods:

```bash
cd ~/atm10-client-updater && git pull -q && cd publisher
python3 publish.py --updater ../updater/ATM10-Updater.cmd
```

`client-mods.json` lists which server jars players need. Use `{"pattern": "...", "curseforge": "<slug>"}` for third-party mods that must not be re-hosted; mods found on Modrinth are linked automatically. `--dry-run` prints the manifest without publishing.
