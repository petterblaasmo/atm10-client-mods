#!/bin/bash
# ATM10 Updater for macOS. Same job as ATM10-Updater.cmd: sync the server's extra client mods
# into the CurseForge ATM10 instance. Uses only tools that ship with macOS (bash 3.2, curl,
# shasum, osascript, launchctl).
#
# Players run:
#   bash <(curl -fsSL https://github.com/petterblaasmo/atm10-client-mods/releases/latest/download/atm10-updater.sh)

set -o pipefail

RELEASE_PAGE='https://github.com/petterblaasmo/atm10-client-mods/releases/latest'
MANIFEST_URL="${ATM10_MANIFEST_URL:-$RELEASE_PAGE/download/manifest.json}"
SUPPORTED_SCHEMA=1
SUPPORT_DIR="$HOME/Library/Application Support/ATM10-Updater"
SETTINGS_FILE="$SUPPORT_DIR/settings"
INSTALLED_SCRIPT="$SUPPORT_DIR/atm10-updater.sh"
LOG_FILE="$HOME/Library/Logs/ATM10-Updater.log"
MAX_LOG_BYTES=262144
AGENT_LABEL='com.github.petterblaasmo.atm10-updater'
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
CHECK_INTERVAL_MINUTES=30
STATE_FILE_NAME='.atm10-updater-state.json'
ALLOWED_PATH='^mods/[A-Za-z0-9._+-]+\.jar$'
ALLOWED_REPLACES='^[A-Za-z0-9._+-]{3,}\*?[A-Za-z0-9._+-]*\.jar$'
ALLOWED_SHA256='^[0-9a-f]{64}$'
ALLOWED_VERSION='^[A-Za-z0-9._-]+$'
INSTANCE_NAME_PATTERN='All the Mods 10|ATM10|ATM 10'
INSTANCE_ROOTS=("$HOME/Documents/curseforge/minecraft/Instances" "$HOME/curseforge/minecraft/Instances")
USER_AGENT='ATM10-Updater-mac/2.0'
SEP=$'\x1f'

BACKGROUND=0
[ "$1" = '--background' ] && BACKGROUND=1
SOURCE="${BASH_SOURCE[0]}"

# ---------------------------------------------------------------- output

log() {
    mkdir -p "${LOG_FILE%/*}"
    if [ -f "$LOG_FILE" ] && [ "$(stat -f %z "$LOG_FILE")" -gt "$MAX_LOG_BYTES" ]; then
        mv -f "$LOG_FILE" "$LOG_FILE.old"
    fi
    printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$1" >> "$LOG_FILE"
}

step() { if [ $BACKGROUND = 1 ]; then log "$1"; else printf '\033[36m==> %s\033[0m\n' "$1"; fi; }
done_() { if [ $BACKGROUND = 1 ]; then log "  $1"; else printf '\033[32m    %s\033[0m\n' "$1"; fi; }
note() { if [ $BACKGROUND = 1 ]; then log "  $1"; else printf '\033[33m    %s\033[0m\n' "$1"; fi; }

die() {
    if [ $BACKGROUND = 1 ]; then log "update failed: $1"; else printf '\n\033[31mUpdate failed: %s\033[0m\n' "$1"; fi
    exit 1
}

notify() {
    /usr/bin/osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' \
        "$1" "$2" >/dev/null 2>&1 || log 'notification failed'
}

# ---------------------------------------------------------------- settings and instance

load_settings() {
    S_INSTANCE='' S_AUTO_UPDATE='' S_NOTIFIED_VERSION=''
    [ -f "$SETTINGS_FILE" ] || return 0
    local key value
    while IFS='=' read -r key value; do
        case $key in
            instance) S_INSTANCE=$value ;;
            autoUpdate) S_AUTO_UPDATE=$value ;;
            notifiedVersion) S_NOTIFIED_VERSION=$value ;;
        esac
    done < "$SETTINGS_FILE"
}

save_settings() {
    mkdir -p "$SUPPORT_DIR"
    printf 'instance=%s\nautoUpdate=%s\nnotifiedVersion=%s\n' "$S_INSTANCE" "$S_AUTO_UPDATE" "$S_NOTIFIED_VERSION" > "$SETTINGS_FILE"
}

is_instance() { [ -n "$1" ] && [ -f "$1/minecraftinstance.json" ] && [ -d "$1/mods" ]; }

find_candidates() {
    CANDIDATES=()
    local root dir
    for root in "${INSTANCE_ROOTS[@]}"; do
        [ -d "$root" ] || continue
        for dir in "$root"/*/; do
            dir=${dir%/}
            [[ ${dir##*/} =~ $INSTANCE_NAME_PATTERN ]] && is_instance "$dir" && CANDIDATES+=("$dir")
        done
    done
}

select_from_list() {
    echo 'Several ATM10 instances were found:'
    local i answer
    for i in "${!CANDIDATES[@]}"; do printf '  [%d] %s\n' $((i + 1)) "${CANDIDATES[$i]}"; done
    while true; do
        read -r -p "Which one do you play on the server? (1-${#CANDIDATES[@]}) " answer || die 'No instance selected.'
        if [[ $answer =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le ${#CANDIDATES[@]} ]; then
            CHOSEN=${CANDIDATES[$((answer - 1))]}
            return
        fi
    done
}

select_with_dialog() {
    CHOSEN=$(/usr/bin/osascript -e 'POSIX path of (choose folder with prompt "Select your ATM10 instance folder (the one that contains the \"mods\" folder)")' 2>/dev/null) ||
        die 'No instance folder selected.'
    CHOSEN=${CHOSEN%/}
}

resolve_instance() {
    if [ -n "$ATM10_INSTANCE" ]; then INSTANCE=${ATM10_INSTANCE%/}; return; fi
    if is_instance "$S_INSTANCE"; then INSTANCE=$S_INSTANCE; return; fi
    [ $BACKGROUND = 1 ] && die 'No ATM10 instance chosen yet; run the updater once in Terminal.'
    find_candidates
    case ${#CANDIDATES[@]} in
        0) note 'Could not find ATM10 in the default CurseForge folder.'; select_with_dialog ;;
        1) CHOSEN=${CANDIDATES[0]} ;;
        *) select_from_list ;;
    esac
    is_instance "$CHOSEN" || die "Not a valid ATM10 instance folder: $CHOSEN"
    S_INSTANCE=$CHOSEN
    save_settings
    INSTANCE=$CHOSEN
}

game_running() {
    # The running game keeps logs/latest.log open.
    local log_file="$1/logs/latest.log"
    if [ -f "$log_file" ] && /usr/sbin/lsof -t "$log_file" >/dev/null 2>&1; then return 0; fi
    /bin/ps -axww -o command= | grep -F -- "$1" | grep -qi java
}

# ---------------------------------------------------------------- manifest and downloads

# Prints one SEP-separated record per line: meta, updater (macUpdater) and file records, or the
# managed paths of a state file. JSON is parsed with JavaScript for Automation, present on every Mac.
read_json() {
    /usr/bin/osascript -l JavaScript - "$1" "$2" "$SEP" <<'JS'
ObjC.import('Foundation');
function run(argv) {
    const [mode, path, sep] = argv;
    const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null).js;
    const data = JSON.parse(text.replace(/^﻿/, ''));
    const s = v => (v === undefined || v === null) ? '' : String(v).replace(/[\r\n\x1f]/g, ' ');
    if (mode === 'state') return [].concat(data.managed || []).map(s).join('\n');
    const out = [['meta', s(data.schema), s(data.version), s(data.pack)].join(sep)];
    if (data.macUpdater) out.push(['updater', s(data.macUpdater.url), s(data.macUpdater.sha256)].join(sep));
    for (const f of data.files || []) out.push(['file', s(f.path), s(f.sha256), s(f.url), s(f.replaces)].join(sep));
    return out.join('\n');
}
JS
}

load_manifest() {
    local file records kind a b c d
    file=$(mktemp -t atm10-manifest) || die 'Could not create a temporary file.'
    if ! /usr/bin/curl -fsSL --proto-redir '=https' --retry 2 -A "$USER_AGENT" -o "$file" "$MANIFEST_URL"; then
        rm -f "$file"
        die 'Could not download the mod list. Check your internet connection and try again.'
    fi
    records=$(read_json manifest "$file" 2>/dev/null)
    local status=$?
    rm -f "$file"
    [ $status = 0 ] || die 'The mod list could not be read. Try again later.'

    M_SCHEMA='' M_VERSION='' M_PACK='' M_UPDATER_URL='' M_UPDATER_SHA256=''
    F_PATH=() F_SHA256=() F_URL=() F_REPLACES=()
    while IFS=$SEP read -r kind a b c d; do
        case $kind in
            meta) M_SCHEMA=$a M_VERSION=$b M_PACK=$c ;;
            updater) M_UPDATER_URL=$a M_UPDATER_SHA256=$b ;;
            file) F_PATH+=("$a") F_SHA256+=("$b") F_URL+=("$c") F_REPLACES+=("$d") ;;
        esac
    done <<< "$records"

    [ "$M_SCHEMA" = "$SUPPORTED_SCHEMA" ] || die "This updater is outdated. Run the install command from $RELEASE_PAGE again."
    [[ $M_VERSION =~ $ALLOWED_VERSION ]] || die "Refusing unsafe version in manifest: $M_VERSION"
    local i
    for i in "${!F_PATH[@]}"; do
        [[ ${F_PATH[$i]} =~ $ALLOWED_PATH ]] || die "Refusing unsafe path in manifest: ${F_PATH[$i]}"
        [ -z "${F_REPLACES[$i]}" ] || [[ ${F_REPLACES[$i]} =~ $ALLOWED_REPLACES ]] || die "Refusing unsafe pattern in manifest: ${F_REPLACES[$i]}"
        [[ ${F_URL[$i]} =~ ^https:// ]] || die "Refusing non-HTTPS download: ${F_URL[$i]}"
        [[ ${F_SHA256[$i]} =~ $ALLOWED_SHA256 ]] || die "Refusing invalid checksum in manifest: ${F_SHA256[$i]}"
    done
    if [ -n "$M_UPDATER_URL" ]; then
        [[ $M_UPDATER_URL =~ ^https:// ]] || die "Refusing non-HTTPS updater: $M_UPDATER_URL"
        [[ $M_UPDATER_SHA256 =~ $ALLOWED_SHA256 ]] || die 'Refusing invalid updater checksum in manifest.'
    fi
}

sha256() { /usr/bin/shasum -a 256 "$1" | cut -d ' ' -f 1; }

save_verified_download() {  # url sha256 target
    local temporary="$3.download"
    if ! /usr/bin/curl -fsSL --proto '=https' --proto-redir '=https' --retry 2 -A "$USER_AGENT" -o "$temporary" "$1"; then
        rm -f "$temporary"
        die "Could not download ${3##*/}. Try again later."
    fi
    if [ "$(sha256 "$temporary")" != "$2" ]; then
        rm -f "$temporary"
        die "Download of ${3##*/} is corrupted (checksum mismatch). Try again later."
    fi
    mv -f "$temporary" "$3"
}

# ---------------------------------------------------------------- mod sync

add_removal() {
    local existing
    for existing in "${REMOVALS[@]}"; do [ "$existing" = "$1" ] && return; done
    REMOVALS+=("$1")
}

find_pending_changes() {
    local mods_dir="$INSTANCE/mods" i target keep file managed wanted
    INSTALLS=() REMOVALS=()
    for i in "${!F_PATH[@]}"; do
        target="$INSTANCE/${F_PATH[$i]}"
        if [ ! -f "$target" ] || [ "$(sha256 "$target")" != "${F_SHA256[$i]}" ]; then INSTALLS+=("$i"); fi
    done
    for i in "${!F_PATH[@]}"; do
        [ -n "${F_REPLACES[$i]}" ] || continue
        keep=${F_PATH[$i]##*/}
        # The pattern is validated to safe characters and one '*', so unquoted globbing is intended.
        for file in "$mods_dir"/${F_REPLACES[$i]}; do
            [ -f "$file" ] && [ "${file##*/}" != "$keep" ] && add_removal "$file"
        done
    done
    if [ -f "$mods_dir/$STATE_FILE_NAME" ]; then
        while IFS= read -r managed; do
            [[ $managed =~ $ALLOWED_PATH ]] || continue
            wanted=0
            for i in "${!F_PATH[@]}"; do [ "${F_PATH[$i]}" = "$managed" ] && wanted=1; done
            [ $wanted = 0 ] && [ -f "$INSTANCE/$managed" ] && add_removal "$INSTANCE/$managed"
        done < <(read_json state "$mods_dir/$STATE_FILE_NAME" 2>/dev/null)
    fi
    PENDING=$((${#INSTALLS[@]} + ${#REMOVALS[@]}))
}

apply_changes() {
    local i path separator=''
    for i in "${INSTALLS[@]}"; do
        save_verified_download "${F_URL[$i]}" "${F_SHA256[$i]}" "$INSTANCE/${F_PATH[$i]}"
        done_ "installed ${F_PATH[$i]##*/}"
    done
    for path in "${REMOVALS[@]}"; do
        rm -f "$path"
        done_ "removed ${path##*/}"
    done
    {
        printf '{\n  "version": "%s",\n  "managed": [' "$M_VERSION"
        for path in "${F_PATH[@]}"; do printf '%s\n    "%s"' "$separator" "$path"; separator=','; done
        printf '\n  ]\n}\n'
    } > "$INSTANCE/mods/$STATE_FILE_NAME"
}

# ---------------------------------------------------------------- background updates

update_installed_updater() {
    [ -n "$M_UPDATER_URL" ] && [ -f "$INSTALLED_SCRIPT" ] || return 0
    [ "$(sha256 "$INSTALLED_SCRIPT")" = "$M_UPDATER_SHA256" ] && return 0
    # mv replaces the file rather than rewriting it, so a copy of this script that is running keeps reading the old one.
    save_verified_download "$M_UPDATER_URL" "$M_UPDATER_SHA256" "$INSTALLED_SCRIPT"
    done_ 'updated the background updater to the newest version'
}

auto_update_installed() {
    [ -f "$INSTALLED_SCRIPT" ] && [ -f "$AGENT_PLIST" ] && launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1
}

install_script() {
    mkdir -p "$SUPPORT_DIR"
    # Run from a file: copy it. Run through bash <(curl ...): fetch the verified release copy.
    if [ -f "$SOURCE" ]; then
        cp -f "$SOURCE" "$INSTALLED_SCRIPT"
    elif [ -n "$M_UPDATER_URL" ]; then
        save_verified_download "$M_UPDATER_URL" "$M_UPDATER_SHA256" "$INSTALLED_SCRIPT"
    else
        return 1
    fi
}

register_auto_update() {
    install_script || { note 'Automatic updates are not available in this release yet.'; return; }
    mkdir -p "${AGENT_PLIST%/*}" "${LOG_FILE%/*}"
    cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$INSTALLED_SCRIPT</string>
        <string>--background</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>$((CHECK_INTERVAL_MINUTES * 60))</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1
    launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" || die 'Could not turn on automatic updates.'
    done_ "Automatic updates are on: checks at login and every $CHECK_INTERVAL_MINUTES minutes, with a notification when mods change."
}

initialize_auto_update() {
    local answer
    if [ -z "$S_AUTO_UPDATE" ]; then
        echo
        read -r -p 'Keep the server mods updated automatically in the background? (Y/n) ' answer
        if [[ $answer =~ ^[[:space:]]*[nN] ]]; then S_AUTO_UPDATE=false; else S_AUTO_UPDATE=true; fi
        save_settings
    fi
    [ "$S_AUTO_UPDATE" = true ] || return 0
    auto_update_installed && return 0
    register_auto_update
}

# ---------------------------------------------------------------- main

main() {
    load_settings
    step 'Finding your ATM10 instance'
    resolve_instance
    done_ "$INSTANCE"

    step 'Checking for server mod updates'
    load_manifest
    done_ "latest server mods: $M_VERSION ($M_PACK)"
    update_installed_updater

    find_pending_changes
    if [ $PENDING -gt 0 ] && game_running "$INSTANCE"; then
        [ $BACKGROUND = 1 ] || die 'Minecraft is running from this instance. Close the game and run the updater again.'
        if [ "$S_NOTIFIED_VERSION" != "$M_VERSION" ]; then
            notify 'ATM10 update ready' 'Close Minecraft and the new server mods install automatically within 30 minutes.'
            S_NOTIFIED_VERSION=$M_VERSION
            save_settings
        fi
        note 'update waiting until Minecraft is closed'
        return 0
    fi

    step 'Updating mods'
    if [ $PENDING = 0 ]; then
        done_ 'Everything is already up to date.'
    else
        apply_changes
        [ $BACKGROUND = 1 ] && notify 'ATM10 mods updated' "Server mods $M_VERSION installed. You are ready to play."
    fi

    if [ $BACKGROUND = 0 ]; then
        initialize_auto_update
        echo
        printf '\033[32mDone! You can start the game from CurseForge now.\033[0m\n'
    fi
}

main "$@"
exit 0
