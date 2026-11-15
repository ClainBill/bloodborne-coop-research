#!/usr/bin/env bash
# Build shadPS4 on a Steam Deck (SteamOS) inside a distrobox container.
#
# SteamOS has an immutable root filesystem, so we do NOT touch the host --
# shadPS4's own docs recommend distrobox for exactly this case. Anything written
# to $HOME persists; the container is just a build toolchain.
#
# The container is Ubuntu 24.04 with clang-19, deliberately matching upstream's
# CI (.github/workflows/build.yml: runs-on ubuntu-24.04, clang-19 from
# apt.llvm.org, mold linker). This is NOT cosmetic:
#
#   An Arch container has a far newer glibc than SteamOS. A binary built there
#   needs GLIBC_2.43/2.44 and GLIBCXX_3.4.35/36 symbols the Deck does not have,
#   so it dies instantly on the host with "version not found". AppImages do not
#   fix this -- they deliberately exclude glibc, because glibc is forward- but
#   not backward-compatible. The only real fix is to build against a glibc no
#   newer than the target's, which is what Ubuntu 24.04 (glibc 2.39) gives us,
#   and is why upstream's own AppImages run on the Deck.
#
# Build type is RelWithDebInfo, deliberately:
#   - A true Debug build of an emulator is unoptimized and will not run
#     Bloodborne at playable speed on the Deck's APU -- you would never reach
#     a summon attempt, which defeats the purpose.
#   - LOG_DEBUG is NOT compiled out in release builds (only LOG_TRACE is).
#     That is 147 of the 166 log sites across np/ and network/, including the
#     RequestSignalingInfos peer-resolution line we care about most.
#
# Usage: ./build-on-deck.sh [src_dir]        (default: ~/shadPS4)

set -euo pipefail

SRC=""
# --patch may be given more than once; patches apply in the order listed.
declare -a PATCHES=()
# The commit the patch was generated against. Pinning avoids upstream drift
# silently breaking the apply; pass --no-pin to build against current master.
BASE_COMMIT="e1cf475263c811e09285f0ff43595a9dab00ed3d"
PIN=1
# Package as an AppImage by default: a bare binary built in the container will
# not run on the SteamOS host, which is where BBLauncher launches it from.
APPIMAGE=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --patch)        PATCHES+=("${2:-}"); shift 2 ;;
        --no-pin)       PIN=0; shift ;;
        --no-appimage)  APPIMAGE=0; shift ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *)         SRC="$1"; shift ;;
    esac
done

SRC="${SRC:-$HOME/shadPS4}"
# Distinct name so the old Arch container is left alone rather than reused.
BOX="shadps4-noble"
IMAGE="ubuntu:24.04"
JOBS="$(nproc)"

# Resolve to absolute paths before any cd, since they may be given relative.
declare -a ABS_PATCHES=()
for p in "${PATCHES[@]:-}"; do
    [[ -z "$p" ]] && continue
    if [[ ! -f "$p" ]]; then
        echo "patch file not found: $p" >&2
        exit 1
    fi
    ABS_PATCHES+=("$(cd "$(dirname "$p")" && pwd)/$(basename "$p")")
done

command -v distrobox >/dev/null 2>&1 || {
    cat >&2 <<'EOF'
distrobox not found.

On SteamOS it normally ships with the system image. If it is missing:
  flatpak install -y flathub io.github.dvlv.boxbuddyrs   # GUI frontend
or install distrobox to your home dir:
  curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install \
      | sh -s -- --prefix ~/.local
  export PATH="$HOME/.local/bin:$PATH"
EOF
    exit 1
}

# --- Container -----------------------------------------------------------
if ! distrobox list | awk '{print $3}' | grep -qx "$BOX"; then
    echo ">> creating container '$BOX' ($IMAGE)"
    distrobox create --name "$BOX" --init --image "$IMAGE" --yes
else
    echo ">> container '$BOX' already exists"
fi

echo ">> installing build dependencies (this takes a few minutes the first time)"
# Package set is upstream's CI list verbatim, plus the extra X11 -dev packages
# SDL3 probes for. shadPS4 vendors SDL3, and SDL checks a wider set than
# shadPS4's own docs mention -- each missing one fails configure with
# "Couldn't find dependency package for <X>". The full chain SDL's CheckX11
# walks is XCURSOR, XDBE, XINPUT, XFIXES, XSYNC, XRANDR, XSCRNSAVER, XSHAPE,
# XTEST.
#
# g++-14 is required, not optional. shadPS4 uses std::ranges::to (a C++23 library
# feature, e.g. common/logging/log.cpp:292) which landed in libstdc++ 14, whereas
# build-essential on Ubuntu 24.04 pulls GCC 13. clang selects the newest GCC
# toolchain it finds, so installing g++-14 alongside is what makes it work.
# Upstream CI gets this for free -- the GitHub runner image ships GCC 14.
#
# WARNING: everything between the quotes below runs inside a SINGLE-QUOTED
# string. An apostrophe anywhere in it -- including in a comment -- closes the
# quote early and the remainder silently executes on the SteamOS host instead,
# where sudo prompts for a password and apt-get does not exist. Keep prose out
# of this block.
distrobox enter "$BOX" -- bash -lc '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

sudo apt-get update
sudo apt-get install -y wget gnupg ca-certificates software-properties-common

# clang-19 from apt.llvm.org, matching upstream CI. Ubuntu 24.04 ships clang-18;
# using the same compiler as upstream keeps us off untested ground.
if ! command -v clang-19 >/dev/null 2>&1; then
    wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key \
        | sudo gpg --dearmor -o /usr/share/keyrings/llvm.gpg
    echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/noble/ llvm-toolchain-noble-19 main" \
        | sudo tee /etc/apt/sources.list.d/llvm19.list >/dev/null
    sudo apt-get update
fi

sudo apt-get install -y \
    clang-19 mold build-essential g++-14 libstdc++-14-dev \
    cmake ninja-build pkg-config git \
    libasound2-dev libpulse-dev libopenal-dev libudev-dev libevdev-dev \
    libssl-dev zlib1g-dev libedit-dev libpng-dev uuid-dev \
    libvulkan-dev vulkan-validationlayers libgles2-mesa-dev libglfw3-dev \
    libx11-dev libxext-dev libxcursor-dev libxi-dev libxrandr-dev \
    libxss-dev libxfixes-dev libxrender-dev libxtst-dev libxinerama-dev \
    libxxf86vm-dev x11proto-dev libxkbcommon-dev libxkbcommon-x11-dev \
    libwayland-dev wayland-protocols libdecor-0-dev \
    libfuse2 file desktop-file-utils
'

# --- Toolchain preflight -------------------------------------------------
# Compile a five-line probe for the newest C++23 library feature the project
# needs. Catching a wrong standard library here costs seconds; discovering it
# 2000 objects into the build costs twenty minutes.
echo ">> checking toolchain supports std::ranges::to"
distrobox enter "$BOX" -- bash -lc '
set -euo pipefail
cat > /tmp/probe.cpp <<EOF
#include <ranges>
#include <string>
#include <vector>
int main() {
    auto v = std::views::iota(1, 4) | std::ranges::to<std::vector<int>>();
    return static_cast<int>(v.size()) - 3;
}
EOF
if clang++-19 -std=gnu++23 -fsyntax-only /tmp/probe.cpp 2>/dev/null; then
    echo "   OK ($(clang++-19 -v /tmp/probe.cpp -std=gnu++23 -fsyntax-only 2>&1 \
        | grep -oE "Selected GCC installation: .*" || echo "toolchain unreported"))"
else
    echo "   !! std::ranges::to unavailable -- clang is not picking up libstdc++ 14." >&2
    echo "   Installed GCC versions:" >&2
    ls -d /usr/lib/gcc/x86_64-linux-gnu/* 2>/dev/null | sed "s/^/     /" >&2
    echo "   Try:  sudo apt-get install -y g++-14 libstdc++-14-dev" >&2
    exit 1
fi
'

# --- Source --------------------------------------------------------------
# Submodules are mandatory: SDL3, spdlog, and the protobuf definitions the
# ShadNet client depends on all live there.
if [[ ! -d "$SRC/.git" ]]; then
    echo ">> cloning shadPS4 (recursive) into $SRC"
    # Full clone, not shallow: we need to be able to check out a pinned commit.
    git clone --recursive https://github.com/shadps4-emu/shadPS4.git "$SRC"
else
    echo ">> using existing checkout at $SRC"
fi

# Reset tracked files to pristine before patching. This script OWNS the source
# tree state rather than trying to infer it: previously it tried to detect an
# already-applied patch, which only worked when the patch was byte-identical.
# The moment a patch was revised, '--3way' would merge the new full diff onto an
# already-modified file, leave conflict markers, and abort. Resetting first makes
# patch application deterministic and re-runnable.
#
# Untracked files (build/, AppDir/, downloaded AppImages) are left alone, so the
# ninja cache survives. Hand edits to tracked source do NOT survive -- put changes
# in a patch file instead.
if [[ -n "$(git -C "$SRC" status --porcelain)" ]]; then
    echo ">> resetting tracked files to pristine (local source edits discarded)"
    git -C "$SRC" reset --quiet --hard HEAD
fi

if [[ "$PIN" -eq 1 ]]; then
    echo ">> pinning to $BASE_COMMIT (the commit the patches were written against)"
    git -C "$SRC" fetch --quiet --all --tags 2>/dev/null || true
    git -C "$SRC" checkout --quiet --force "$BASE_COMMIT" || {
        echo "   could not check out $BASE_COMMIT -- pass --no-pin to use master" >&2
        exit 1
    }
fi
git -C "$SRC" submodule update --init --recursive

# Remove untracked files under src/ so patches that CREATE new source files
# (e.g. a new header like np_coop_trace.h) are re-runnable. A prior apply leaves
# such files behind; 'git reset --hard' does NOT remove untracked files, so the
# next 'git apply --check' fails with "already exists in working directory".
# Scoped to src/ to preserve the build/ ninja cache and downloaded AppImages.
git -C "$SRC" clean -fdq -- src/

# --- Patch ---------------------------------------------------------------
# Plain 'git apply', deliberately not '--3way'. The tree is pristine at this
# point, so a patch either applies exactly or is wrong -- and plain apply is
# atomic, leaving the tree untouched on failure. '--3way' would instead write
# conflict markers into the source and hand a broken tree to the compiler.
for P in "${ABS_PATCHES[@]:-}"; do
    [[ -z "$P" ]] && continue
    echo ">> applying $(basename "$P")"
    if ! apply_err=$(git -C "$SRC" apply --check "$P" 2>&1); then
        echo "   !! patch does not apply to $BASE_COMMIT: $P" >&2
        echo "   git apply --check said:" >&2
        echo "$apply_err" | sed 's/^/     /' >&2
        echo "   If it is a context mismatch, regenerate the patch (or pass --no-pin)." >&2
        echo "   If it says \"already exists\", an untracked file survived a prior run." >&2
        exit 1
    fi
    git -C "$SRC" apply "$P"
    echo "   applied cleanly"
done

# Belt and braces: never hand conflict markers to the compiler.
if git -C "$SRC" grep -qlE '^(<{7}|={7}|>{7})' -- 'src/*' 2>/dev/null; then
    echo "!! conflict markers found in source after patching -- aborting" >&2
    git -C "$SRC" grep -lE '^(<{7}|={7}|>{7})' -- 'src/*' >&2
    exit 1
fi

# --- Build ---------------------------------------------------------------
echo ">> configuring and building (RelWithDebInfo, $JOBS jobs)"
distrobox enter "$BOX" -- bash -lc "
set -euo pipefail
cd '$SRC'
cmake -S . -B build \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_C_COMPILER=clang-19 \
    -DCMAKE_CXX_COMPILER=clang++-19 \
    -DCMAKE_EXE_LINKER_FLAGS='-fuse-ld=mold' \
    -DCMAKE_SHARED_LINKER_FLAGS='-fuse-ld=mold'
cmake --build build --parallel $JOBS
"

BIN="$SRC/build/shadps4"
if [[ ! -x "$BIN" ]]; then
    echo "build finished but '$BIN' not found -- check the output above" >&2
    exit 1
fi
echo ">> built: $BIN"

# --- Package -------------------------------------------------------------
# The bare binary links against the *container's* libraries. BBLauncher runs on
# the SteamOS host, which does not have them -- the process dies instantly on a
# missing .so and the launcher just appears to do nothing. Bundling into an
# AppImage (what upstream CI ships) makes it self-contained and host-runnable.
if [[ "$APPIMAGE" -eq 1 ]]; then
    echo ">> packaging AppImage"
    distrobox enter "$BOX" -- bash -lc "
set -euo pipefail
cd '$SRC'
# APPIMAGE_EXTRACT_AND_RUN: containers usually lack FUSE, so the linuxdeploy
# AppImage cannot mount itself and must extract instead.
export APPIMAGE_EXTRACT_AND_RUN=1

if [[ ! -f linuxdeploy-x86_64.AppImage ]]; then
    wget -q --tries=5 --timeout=15 \
        https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
fi
if [[ ! -f linuxdeploy-plugin-checkrt-x86_64.sh ]]; then
    wget -q --tries=5 --timeout=15 \
        https://github.com/linuxdeploy/linuxdeploy-plugin-checkrt/releases/download/continuous/linuxdeploy-plugin-checkrt-x86_64.sh
fi
chmod a+x linuxdeploy-x86_64.AppImage linuxdeploy-plugin-checkrt-x86_64.sh

rm -rf AppDir
./linuxdeploy-x86_64.AppImage --appdir AppDir
./linuxdeploy-plugin-checkrt-x86_64.sh --appdir AppDir
./linuxdeploy-x86_64.AppImage --appdir AppDir \
    -d src/dist/net.shadps4.shadPS4.desktop \
    -e build/shadps4 \
    -i src/dist/net.shadps4.shadPS4.svg \
    --output appimage
mv -f shadPS4-x86_64.AppImage Shadps4-sdl.AppImage
"
    APP="$SRC/Shadps4-sdl.AppImage"
    if [[ ! -f "$APP" ]]; then
        echo "AppImage packaging failed -- see output above" >&2
        exit 1
    fi
    chmod a+x "$APP"
    echo
    echo "AppImage: $APP"
    echo
    echo "Point BBLauncher at that file (Manage Builds -> add local build)."
    echo "Do NOT use $BIN -- it only runs inside the container."
    echo
    echo "Then:  ./capture-bb-net.sh --launcher ~/Applications/bbQtlauncher.appimage"
else
    echo
    echo "Bare binary: $BIN"
    echo "NOTE: this only runs inside the '$BOX' container. BBLauncher runs on"
    echo "      the host and will fail to launch it. Drop --no-appimage to get"
    echo "      a self-contained build."
fi
