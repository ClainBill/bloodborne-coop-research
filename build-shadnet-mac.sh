#!/usr/bin/env bash
# Build shadNet on macOS and seed a config with matchmaking enabled.
#
# shadNet is the PSN replacement: it hosts the matching2 rooms and resolves an
# NPID to a peer's external IP/port (cmd_matching.cpp CmdRequestSignalingInfos).
# Bloodborne co-op needs it -- the BB session server only hands out SOS signs;
# the actual peer address exchange happens here.
#
# Matching2 ships DISABLED (config.h: m_matching2Enabled = false), which is why
# the public instance cannot broker co-op. The generated config turns it on.
#
# Unlike shadPS4 -- which is x86_64-only on macOS and therefore runs under
# Rosetta -- shadNet is plain Qt6 and builds natively on Apple Silicon.
#
# Usage: ./build-shadnet-mac.sh [src_dir]      (default: /Volumes/WillemsWork/dev/shadNet)

set -euo pipefail

SRC="${1:-/Volumes/WillemsWork/dev/shadNet}"

[[ -d "$SRC/.git" ]] || { echo "shadNet checkout not found at $SRC" >&2; exit 1; }

command -v brew >/dev/null 2>&1 || {
    echo "Homebrew required: https://brew.sh" >&2
    exit 1
}

echo ">> installing build dependencies"
brew install --quiet qt cmake ninja pkg-config 2>&1 | tail -3 || true

QT_PREFIX="$(brew --prefix qt)"
echo "   Qt6 at $QT_PREFIX"

# The protobuf submodule is mandatory -- CMake will not configure without it.
echo ">> fetching submodules"
git -C "$SRC" submodule update --init --recursive

echo ">> configuring and building"
cmake -S "$SRC" -B "$SRC/build" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$QT_PREFIX"
cmake --build "$SRC/build" --parallel "$(sysctl -n hw.ncpu)"

BIN="$SRC/build/shadnet"
[[ -x "$BIN" ]] || { echo "build finished but $BIN missing" >&2; exit 1; }

# --- Config --------------------------------------------------------------
# shadnet.cfg is read from the working directory (config.h: Load(path =
# "shadnet.cfg")), so it must sit next to wherever the binary is launched from.
CFG="$SRC/build/shadnet.cfg"
if [[ -f "$CFG" ]]; then
    echo ">> $CFG already exists, leaving it alone"
    grep -q "^Matching2Enabled=true" "$CFG" \
        || echo "   !! Matching2Enabled is not true -- co-op will not work" >&2
else
    cat > "$CFG" <<'EOF'
[General]
; 0.0.0.0 not 127.0.0.1: the other machine has to reach this one.
Host=0.0.0.0
UnsecuredPort=31313
MatchingUdpPort=31314
WebApiPort=31315
StatsPort=31320
; The switch. Ships false; the public instance runs it false, which is why
; co-op cannot be brokered there.
Matching2Enabled=true
StatsEnabled=true
EmailValidated=false
EOF
    echo ">> wrote $CFG (Matching2Enabled=true, Host=0.0.0.0)"
fi

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '<mac-lan-ip>')"

cat <<EOF

built: $BIN

Run it from its own directory so it finds shadnet.cfg:
    cd $SRC/build && ./shadnet

This Mac is $LAN_IP. On BOTH game machines:

  1. shadPS4 setting 'shadnet_server'  ->  $LAN_IP:31313
  2. host_overrides.json:
       {
         "ss4.scej-network.jp": "http://$LAN_IP",
         "thehuntersdream.com": "http://$LAN_IP"
       }
  3. Run the Bloodborne session server here too:
       python3 bb-server.py            (ports 18671 + 20443)

Ports this Mac must accept: 31313/tcp 31314/udp 31315/tcp 18671/tcp 20443/tcp
The two game clients also talk directly to each other on 3658/udp.
EOF
