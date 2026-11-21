# ATM10 client mods

Extra client mods for our All the Mods 10 server, on top of the CurseForge pack.

## Players

1. Download **[ATM10-Updater.cmd](https://github.com/petterblaasmo/atm10-client-mods/releases/latest/download/ATM10-Updater.cmd)** once and double-click it.
2. Answer **Y** when it asks to keep the mods updated automatically. That's it.

From then on it runs invisibly at sign-in and every 30 minutes, updates itself, and shows a Windows notification when mods were updated. If Minecraft is open when an update arrives, you get one notification asking you to close the game; it installs as soon as the game is closed.

The updater finds your ATM10 instance, verifies every download, and removes old versions it installed. It never touches the rest of your pack. If Windows SmartScreen warns about the file, choose **More info → Run anyway**.

To turn automatic updates off: `schtasks /Delete /TN "ATM10 Updater" /F`. Logs: `%LOCALAPPDATA%\ATM10-Updater\updater.log`.

## Admins

On the server, after changing mods:

```bash
cd ~/atm10-client-updater && git pull -q && cd publisher
python3 publish.py --updater ../updater/ATM10-Updater.cmd
```

`client-mods.json` lists which server jars players need. Use `{"pattern": "...", "curseforge": "<slug>"}` for third-party mods that must not be re-hosted; mods found on Modrinth are linked automatically. `--dry-run` prints the manifest without publishing.
