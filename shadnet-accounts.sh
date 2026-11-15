#!/usr/bin/env bash
# Create accounts on a self-hosted shadNet instance.
#
# Registration is not a web signup -- it is CommandType::Create over shadNet's
# own TCP protocol (cmd_account.cpp CmdCreate), so it needs a protocol client.
# The repo ships one in clientsample/, which is a separate CMake project and is
# NOT built by the main build; this builds it on demand.
#
# IMPORTANT -- name the account after the shadPS4 profile.
#   The game reports its PSN online ID from the shadPS4 user profile name (your
#   capture shows sceNpSignalingCreateContext owner='ClainBill'), and the peer
#   NPID travels to the other player inside the BB SummonData blob. shadNet then
#   resolves that NPID against whatever name the peer LOGGED IN with
#   (cmd_matching.cpp CmdRequestSignalingInfos). If the shadNet npid and the
#   shadPS4 profile name differ, that lookup fails and signaling never starts.
#
# npid rules (client_session.h IsValidNpid): 3-16 chars, letters/digits/-/_ only.
#
# Usage:
#   ./shadnet-accounts.sh <npid> <password> <email> [more npid pw email ...]
#   ./shadnet-accounts.sh ClainBill hunter1 clain@example.com Brother hunter2 bro@example.com

set -euo pipefail

SRC="/Volumes/WillemsWork/dev/shadNet"
HOST="127.0.0.1"
PORT="31313"
SECRET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)    SRC="${2:-}"; shift 2 ;;
        --host)   HOST="${2:-}"; shift 2 ;;
        --port)   PORT="${2:-}"; shift 2 ;;
        --secret) SECRET="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) break ;;
    esac
done

[[ $# -ge 3 && $(( $# % 3 )) -eq 0 ]] || {
    echo "need triples of: <npid> <password> <email>" >&2
    echo "e.g. $0 ClainBill hunter1 a@example.com Brother hunter2 b@example.com" >&2
    exit 1
}

[[ -d "$SRC/clientsample" ]] || { echo "shadNet checkout not found at $SRC" >&2; exit 1; }

BIN="$SRC/clientsample/build/shadnet-sample"
if [[ ! -x "$BIN" ]]; then
    echo ">> building shadnet-sample (protobuf only, no Qt)"
    cmake -S "$SRC/clientsample" -B "$SRC/clientsample/build" -G Ninja -DCMAKE_BUILD_TYPE=Release
    cmake --build "$SRC/clientsample/build" --parallel "$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
fi
[[ -x "$BIN" ]] || { echo "build produced no $BIN" >&2; exit 1; }

# Fail fast on names the server will reject, rather than after a round trip.
validate_npid() {
    local n="$1"
    [[ ${#n} -ge 3 && ${#n} -le 16 ]] || { echo "  !! '$n': must be 3-16 chars" >&2; return 1; }
    [[ "$n" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "  !! '$n': letters/digits/-/_ only" >&2; return 1; }
    [[ "$n" != "DeletedUser" ]] || { echo "  !! 'DeletedUser' is reserved" >&2; return 1; }
}

echo ">> registering against $HOST:$PORT"
while [[ $# -gt 0 ]]; do
    NPID="$1"; PASS="$2"; MAIL="$3"; shift 3
    echo
    echo "-- $NPID <$MAIL>"
    validate_npid "$NPID" || continue
    if [[ -n "$SECRET" ]]; then
        "$BIN" "$HOST" "$PORT" register "$NPID" "$PASS" "$MAIL" "$SECRET" || true
    else
        "$BIN" "$HOST" "$PORT" register "$NPID" "$PASS" "$MAIL" || true
    fi
done

cat <<'EOF'

Registered. Now set the credentials on each machine, in shadPS4's user profile:
    shadnet_npid      = the name you registered
    shadnet_password  = its password
    shadnet_enabled   = true
and enable ShadNet itself (shad_net_enabled), pointing shadnet_server at this Mac.

Reminder: shadnet_npid MUST match that machine's shadPS4 profile name, or peer
resolution fails at the signaling step.
EOF
