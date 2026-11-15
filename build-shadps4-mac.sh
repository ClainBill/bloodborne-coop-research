#!/usr/bin/env bash
# Build shadPS4 with the P2P patch on macOS (Apple Silicon).
#
# The Mac instance needs the patched emulator just as much as the Deck does --
# an unpatched build has every P2PSocket method stubbed, so its side of the
# session cannot send or receive a single datagram.
#
# macOS specifics that differ from the Linux build:
#   - shadPS4 is x86_64-only here (-DCMAKE_OSX_ARCHITECTURES=x86_64), so on
#     Apple Silicon it runs under Rosetta 2. CMakeLists.txt:72 drops
#     /opt/homebrew from the prefix path when cross-compiling, because ARM
#     Homebrew libraries cannot link into an x86_64 binary.
#   - No distrobox: there is no immutable filesystem to work around.
#   - ENABLE_SYSTEM_VULKAN defaults OFF on Apple, so the KosmicKrisp Vulkan
#     driver is built from source and needs the meson/llvm/spirv toolchain.
#     Pass --system-vulkan to skip that if you already have MoltenVK set up.
#
# Usage:
#   ./build-shadps4-mac.sh --patch p2p-sockets.patch --patch fix-missing-includes.patch

set -euo pipefail

SRC="/Volumes/WillemsWork/dev/shadPS4"
declare -a PATCHES=()
BASE_COMMIT="e1cf475263c811e09285f0ff43595a9dab00ed3d"
PIN=1
SYSTEM_VULKAN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --patch)          PATCHES+=("${2:-}"); shift 2 ;;
        --no-pin)         PIN=0; shift ;;
        --system-vulkan)  SYSTEM_VULKAN=1; shift ;;
        --src)            SRC="${2:-}"; shift 2 ;;
        -h|--help)        sed -n '2,19p' "$0"; exit 0 ;;
        *)                echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

declare -a ABS_PATCHES=()
for p in "${PATCHES[@]:-}"; do
    [[ -z "$p" ]] && continue
    [[ -f "$p" ]] || { echo "patch not found: $p" >&2; exit 1; }
    ABS_PATCHES+=("$(cd "$(dirname "$p")" && pwd)/$(basename "$p")")
done

command -v brew >/dev/null 2>&1 || { echo "Homebrew required: https://brew.sh" >&2; exit 1; }
xcode-select -p >/dev/null 2>&1 || {
    echo "Xcode command line tools missing. Run: xcode-select --install" >&2
    exit 1
}

echo ">> installing build dependencies"
brew install --quiet cmake ninja 2>&1 | tail -2 || true
if [[ "$SYSTEM_VULKAN" -eq 0 ]]; then
    # Required to build the bundled KosmicKrisp Vulkan driver.
    brew install --quiet meson pkg-config llvm spirv-tools spirv-llvm-translator libclc 2>&1 | tail -2 || true
    python3 -m pip install --quiet --break-system-packages mako packaging pyyaml 2>/dev/null || true
fi

# --- Source --------------------------------------------------------------
if [[ ! -d "$SRC/.git" ]]; then
    echo ">> cloning shadPS4 into $SRC"
    git clone --recursive https://github.com/shadps4-emu/shadPS4.git "$SRC"
else
    echo ">> using existing checkout at $SRC"
fi

# Own the tree state rather than inferring it: patches then apply onto a known
# base every time, so re-runs are safe and cannot leave conflict markers.
if [[ -n "$(git -C "$SRC" status --porcelain)" ]]; then
    echo ">> resetting tracked files (local source edits discarded)"
    git -C "$SRC" reset --quiet --hard HEAD
fi

if [[ "$PIN" -eq 1 ]]; then
    echo ">> pinning to $BASE_COMMIT"
    git -C "$SRC" checkout --quiet --force "$BASE_COMMIT" 2>/dev/null || {
        echo "   could not check out $BASE_COMMIT (shallow clone?) -- using HEAD" >&2
    }
fi

echo ">> fetching submodules (large; first run takes a while)"
git -C "$SRC" submodule update --init --recursive

# --- Patch ---------------------------------------------------------------
for P in "${ABS_PATCHES[@]:-}"; do
    [[ -z "$P" ]] && continue
    echo ">> applying $(basename "$P")"
    git -C "$SRC" apply --check "$P" 2>/dev/null || {
        echo "   !! does not apply to this checkout: $P" >&2
        exit 1
    }
    git -C "$SRC" apply "$P"
    echo "   applied cleanly"
done

if git -C "$SRC" grep -qlE '^(<{7}|={7}|>{7})' -- 'src/*' 2>/dev/null; then
    echo "!! conflict markers in source -- aborting" >&2
    exit 1
fi

# --- Build ---------------------------------------------------------------
declare -a CMAKE_ARGS=(
    -S "$SRC" -B "$SRC/build-mac"
    -G Ninja
    -DCMAKE_BUILD_TYPE=RelWithDebInfo
    -DCMAKE_OSX_ARCHITECTURES=x86_64
)
[[ "$SYSTEM_VULKAN" -eq 1 ]] && CMAKE_ARGS+=(-DENABLE_SYSTEM_VULKAN=ON)

echo ">> configuring (x86_64 -- will run under Rosetta)"
cmake "${CMAKE_ARGS[@]}"

echo ">> building"
cmake --build "$SRC/build-mac" --parallel "$(sysctl -n hw.ncpu)"

BIN="$SRC/build-mac/shadps4"
[[ -x "$BIN" ]] || { echo "build finished but $BIN missing" >&2; exit 1; }

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || echo '<mac-lan-ip>')"
cat <<EOF

built: $BIN
  arch: $(lipo -archs "$BIN" 2>/dev/null || file -b "$BIN")

Run it directly (it is a CLI app):
    $BIN --game /path/to/CUSA00900/eboot.bin

Point this instance at the servers on this Mac ($LAN_IP):
  - shadPS4 setting 'shadnet_server' -> $LAN_IP:31313
  - host_overrides.json in this build's user dir:
      {
        "ss4.scej-network.jp": "http://$LAN_IP",
        "thehuntersdream.com": "http://$LAN_IP"
      }

Note the user dir: shadPS4 prefers ./user next to the working directory,
otherwise ~/Library/Application Support/shadPS4 on macOS.
EOF
