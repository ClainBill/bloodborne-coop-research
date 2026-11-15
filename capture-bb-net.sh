#!/usr/bin/env bash
# Capture Bloodborne's Np/Net call trace under shadPS4.
#
# Answers the decisive question: does Bloodborne drive libSceNpMatching2 for
# co-op sessions, or does it pull peer info from FromSoft's server and run its
# own session over raw libSceNet sockets?
#
# Two modes:
#   Direct    ./capture-bb-net.sh /path/to/shadps4[.AppImage]
#   Launcher  ./capture-bb-net.sh --launcher ~/Applications/bbQtlauncher.appimage
#             (patches config, runs BBLauncher, collects the log once you
#              close it)
#
# Options:
#   --launcher         Go through BBLauncher. Give it the launcher's path to
#                      have it started for you; omit the path to start it
#                      yourself and press ENTER when done.
#   --user-dir DIR     shadPS4 user dir (skip auto-detection).
#   --serial SERIAL    Game serial. Default CUSA00900 (Bloodborne US).
#                      Others: CUSA03173 CUSA00208 CUSA00207 CUSA01363
#                              CUSA03023 CUSA00299 CUSA03014

set -euo pipefail

EMU=""
SERIAL="CUSA00900"
USER_DIR=""
LAUNCHER_MODE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --launcher)  LAUNCHER_MODE=1; shift ;;
        --user-dir)  USER_DIR="${2:-}"; shift 2 ;;
        --serial)    SERIAL="${2:-}"; shift 2 ;;
        -h|--help)   sed -n '2,24p' "$0"; exit 0 ;;
        *)           EMU="$1"; shift ;;
    esac
done

if [[ -n "$EMU" && ! -x "$EMU" ]]; then
    if [[ -f "$EMU" ]]; then
        echo "Not executable: $EMU" >&2
        echo "AppImages need:  chmod +x '$EMU'" >&2
    else
        echo "No such file: $EMU" >&2
    fi
    exit 1
fi
if [[ "$LAUNCHER_MODE" -eq 0 && -z "$EMU" ]]; then
    echo "usage: $0 /path/to/shadps4[.AppImage]" >&2
    echo "   or: $0 --launcher [/path/to/bblauncher.AppImage]" >&2
    exit 1
fi

# --- Locate shadPS4's user directory -------------------------------------
# BBLauncher and shadPS4 agree on this logic (Common.cpp:66 / path_util.cpp:87):
# a portable "user" dir wins, otherwise XDG. But BBLauncher sets the emulator's
# working directory itself (ipc_client.cpp:54) based on its UserFolderLocation
# setting -- usually <shadPS4 binary dir>/user. So when launching through
# BBLauncher, the active config is very often NOT ~/.local/share/shadPS4.
if [[ -z "$USER_DIR" ]]; then
    declare -a CANDIDATES=()
    [[ -f "$PWD/user/config.json" ]] && CANDIDATES+=("$PWD/user")
    [[ -n "${XDG_DATA_HOME:-}" && -f "$XDG_DATA_HOME/shadPS4/config.json" ]] \
        && CANDIDATES+=("$XDG_DATA_HOME/shadPS4")
    [[ -f "$HOME/.local/share/shadPS4/config.json" ]] \
        && CANDIDATES+=("$HOME/.local/share/shadPS4")
    [[ -n "$EMU" && -f "$(dirname "$EMU")/user/config.json" ]] \
        && CANDIDATES+=("$(dirname "$EMU")/user")

    # Sweep for portable user dirs created by BBLauncher-managed builds.
    while IFS= read -r c; do
        CANDIDATES+=("$(dirname "$c")")
    done < <(find "$HOME" -maxdepth 6 -type f -name config.json -path '*/user/*' \
                  -not -path '*/.cache/*' 2>/dev/null | head -20)

    # De-duplicate, preserving order.
    declare -a UNIQ=()
    for c in "${CANDIDATES[@]:-}"; do
        [[ -z "$c" ]] && continue
        local_dup=0
        for u in "${UNIQ[@]:-}"; do [[ "$u" == "$c" ]] && local_dup=1 && break; done
        [[ "$local_dup" -eq 0 ]] && UNIQ+=("$c")
    done

    if [[ "${#UNIQ[@]}" -eq 0 ]]; then
        echo "No shadPS4 config.json found." >&2
        echo "Launch the game once via BBLauncher so it generates one, then re-run." >&2
        echo "Or pass it explicitly:  $0 --launcher --user-dir /path/to/user" >&2
        exit 1
    elif [[ "${#UNIQ[@]}" -gt 1 ]]; then
        echo "Multiple shadPS4 user dirs found -- pick the one BBLauncher uses:" >&2
        echo >&2
        for u in "${UNIQ[@]}"; do
            printf '  %s   (config modified %s)\n' \
                "$u" "$(date -r "$u/config.json" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')" >&2
        done
        echo >&2
        echo "Re-run with:  $0 $* --user-dir <dir>" >&2
        echo "Tip: BBLauncher > Open Folders > Log Folder shows you the active one." >&2
        exit 1
    fi
    USER_DIR="${UNIQ[0]}"
fi

CONFIG="$USER_DIR/config.json"
GAME_CONFIG="$USER_DIR/custom_configs/$SERIAL.json"
LOG_SRC="$USER_DIR/log/shad_log.txt"

[[ -f "$CONFIG" ]] || { echo "No config.json at $CONFIG" >&2; exit 1; }

echo "user dir : $USER_DIR"
echo "config   : $CONFIG"

# --- Log filter ----------------------------------------------------------
# Space-separated Class:level pairs; '*' sets the default (log.cpp:285).
# LOG_DEBUG is NOT compiled out in release builds (only LOG_TRACE is), so this
# works against a stock nightly AppImage.
FILTER="*:info \
Lib.NpMatching2:debug \
Lib.NpSignaling:debug \
Lib.NpManager:debug \
Lib.NpCommon:debug \
Lib.NpWebApi:debug \
Lib.NpWebApi2:debug \
Lib.NpAuth:debug \
Lib.Net:debug \
Lib.NetCtl:debug \
Lib.Http:debug \
Lib.Http2:debug \
Lib.Ssl:debug"

STAMP="$(date +%Y%m%d-%H%M%S)"
declare -a BACKUPS=()

backup_and_patch() {
    local target="$1"
    [[ -f "$target" ]] || return 0
    local bak="$target.bak.$STAMP"
    cp "$target" "$bak"
    BACKUPS+=("$target|$bak")
    python3 - "$target" "$FILTER" <<'PY'
import json, sys
path, filt = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
log = cfg.setdefault("Log", {})
log["filter"] = filt
log["enable"] = True
log["sync"] = True             # don't lose the tail on a crash
log["skip_duplicate"] = False  # we want every repeated socket call
cfg["Log"] = log
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
PY
    echo "patched  : $target"
}

restore() {
    for pair in "${BACKUPS[@]:-}"; do
        [[ -z "$pair" ]] && continue
        cp "${pair#*|}" "${pair%|*}"
    done
    [[ "${#BACKUPS[@]}" -gt 0 ]] && echo "config restored"
}
trap restore EXIT

backup_and_patch "$CONFIG"

# A per-game override file wins over the global config: emulator_settings.cpp:430
# applies its "Log" section as game_specific_value, and 'filter' IS in
# LogSettings::GetOverrideableFields(). BBLauncher's log-filter UI writes here,
# so it would silently override us. Patch it too if it exists.
if [[ -f "$GAME_CONFIG" ]]; then
    echo "NOTE     : game-specific config found -- it overrides the global one."
    backup_and_patch "$GAME_CONFIG"
fi

mkdir -p "$(dirname "$LOG_SRC")"
: > "$LOG_SRC"

OUT="$PWD/capture-$STAMP.log"

cat <<'EOF'

--------------------------------------------------------------------
  What to do once the game is running:

   1. Get to a lamp / Hunter's Dream so the game is online-active.
      (Sanity check: can you see other players' blood messages?)
   2. Use the Small Resonant Bell (or Beckoning Bell) to summon.
   3. Let it search for ~60 seconds even if nothing is found.
   4. Ring the Silencing Blank to stop, then quit the game.

  The search attempt is the important part -- it exercises the
  matchmaking path whether or not a peer is ever found.
--------------------------------------------------------------------

EOF

if [[ "$LAUNCHER_MODE" -eq 1 ]]; then
    echo "Do NOT change log settings in BBLauncher's shadPS4 Settings while"
    echo "running -- saving there rewrites config.json and clobbers the filter."
    echo
    if [[ -n "$EMU" ]]; then
        echo "launching BBLauncher: $EMU"
        echo "(this script resumes once you CLOSE BBLauncher)"
        echo
        set +e
        "$EMU"
        set -e
        echo
        echo "BBLauncher exited"
    else
        cat <<'EOF'
  1. Start BBLauncher now and launch Bloodborne as you normally would.
  2. Do the summon attempt above.
  3. Quit the game AND close BBLauncher.
  4. Come back here and press ENTER.

EOF
        read -r -p "Press ENTER once you've quit the game... " _
    fi
else
    echo "launching: $EMU $SERIAL"
    echo
    set +e
    "$EMU" "$SERIAL"
    EMU_RC=$?
    set -e
    echo
    echo "emulator exited (rc=$EMU_RC)"
fi

if [[ -s "$LOG_SRC" ]]; then
    cp "$LOG_SRC" "$OUT"
    echo
    echo "capture saved: $OUT"
    echo "lines: $(wc -l < "$OUT")"
    echo
    echo "Now run:  ./analyze-capture.sh $OUT"
else
    echo >&2
    echo "WARNING: log at $LOG_SRC is missing or empty." >&2
    echo "Most likely the wrong user dir -- BBLauncher may be pointing shadPS4" >&2
    echo "somewhere else. Check BBLauncher > Open Folders > Log Folder and" >&2
    echo "re-run with --user-dir <that dir's parent>." >&2
    exit 1
fi
