#!/usr/bin/env bash
# Capture Bloodborne's session-server HTTP traffic, bodies included.
#
# Points shadPS4's host_overrides.json at a local logging proxy, starts the
# proxy, runs BBLauncher, then restores the override on exit. The transcript
# holds every request and response the game exchanged with the session server.
#
# Usage:
#   ./capture-http.sh                                   # you launch the game
#   ./capture-http.sh ~/Applications/BB_Launcher-qt.AppImage
#   ./capture-http.sh --user-dir /path/to/user [launcher]

set -euo pipefail

LAUNCHER=""
USER_DIR=""
UPSTREAM="thehuntersdream.com"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user-dir) USER_DIR="${2:-}"; shift 2 ;;
        --upstream) UPSTREAM="${2:-}"; shift 2 ;;
        -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
        *)          LAUNCHER="$1"; shift ;;
    esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY="$HERE/bb-proxy.py"
[[ -f "$PROXY" ]] || { echo "bb-proxy.py not found next to this script" >&2; exit 1; }

# --- Locate shadPS4's user directory -------------------------------------
if [[ -z "$USER_DIR" ]]; then
    if [[ -f "$HOME/.local/share/shadPS4/config.json" ]]; then
        USER_DIR="$HOME/.local/share/shadPS4"
    else
        c=$(find "$HOME" -maxdepth 6 -type f -name config.json -path '*/user/*' \
                -not -path '*/.cache/*' 2>/dev/null | head -1 || true)
        [[ -n "$c" ]] && USER_DIR="$(dirname "$c")"
    fi
fi
[[ -n "$USER_DIR" && -d "$USER_DIR" ]] || {
    echo "Could not find shadPS4 user dir. Pass --user-dir <path>." >&2
    exit 1
}

OVERRIDES="$USER_DIR/host_overrides.json"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="$PWD/http-capture-$STAMP"
mkdir -p "$OUTDIR"

echo "user dir  : $USER_DIR"
echo "overrides : $OVERRIDES"
echo "output    : $OUTDIR"

# --- Redirect the game at the proxy --------------------------------------
# No target port on purpose: shadPS4 preserves the original port when the
# replacement omits one (http.cpp:395), so 18671 and 20443 both land locally
# from a single pair of entries -- including URLs the game only learns at
# runtime from ss.info.
BACKUP=""
if [[ -f "$OVERRIDES" ]]; then
    BACKUP="$OVERRIDES.bak.$STAMP"
    cp "$OVERRIDES" "$BACKUP"
    echo "backup    : $BACKUP"
fi

PROXY_PID=""
cleanup() {
    [[ -n "$PROXY_PID" ]] && kill "$PROXY_PID" 2>/dev/null || true
    if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
        cp "$BACKUP" "$OVERRIDES"
        echo "host_overrides.json restored"
    else
        rm -f "$OVERRIDES"
        echo "host_overrides.json removed (there was none before)"
    fi
    echo
    echo "transcript(s):"
    ls -1 "$OUTDIR" 2>/dev/null | sed 's/^/  /' || true
}
trap cleanup EXIT

cat > "$OVERRIDES" <<EOF
{
  "ss4.scej-network.jp": "http://127.0.0.1",
  "$UPSTREAM": "http://127.0.0.1"
}
EOF
echo "override written -> 127.0.0.1"

# --- Start the proxy -----------------------------------------------------
python3 "$PROXY" --upstream "$UPSTREAM" --outdir "$OUTDIR" --raw &
PROXY_PID=$!
sleep 1
kill -0 "$PROXY_PID" 2>/dev/null || { echo "proxy failed to start" >&2; exit 1; }

cat <<'EOF'

--------------------------------------------------------------------
  In game:
   1. Load a save and reach a lamp so the game goes online.
   2. Ring the Small Resonant Bell and let it search ~60s.
   3. Also ring the Beckoning Bell (the host side of a summon) --
      that is the request we most need and have never captured.
   4. Quit the game, then close BBLauncher.
--------------------------------------------------------------------

EOF

if [[ -n "$LAUNCHER" ]]; then
    [[ -x "$LAUNCHER" ]] || { echo "not executable: $LAUNCHER" >&2; exit 1; }
    echo "launching: $LAUNCHER"
    "$LAUNCHER" || true
    echo "launcher exited"
else
    read -r -p "Start the game yourself, then press ENTER when done... " _
fi
