#!/usr/bin/env bash
# Triage a capture from capture-bb-net.sh and answer the architecture question:
#
#   (A) Bloodborne drives libSceNpMatching2  -> shadPS4's existing P2P stack
#       carries us; we only need to write the session server.
#
#   (B) Bloodborne uses its own transport over raw libSceNet sockets after
#       getting peer info from FromSoft's server -> real emulator work needed.
#
# Usage: ./analyze-capture.sh capture-YYYYmmdd-HHMMSS.log

set -euo pipefail

LOG="${1:-}"
if [[ -z "$LOG" || ! -f "$LOG" ]]; then
    echo "usage: $0 <capture.log>" >&2
    exit 1
fi

hdr() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
count() { grep -acE "$1" "$LOG" || true; }

echo "analyzing: $LOG  ($(wc -l < "$LOG") lines)"

hdr "Log class volume"
grep -oE '\[Lib\.(Np[A-Za-z0-9]*|Net[A-Za-z0-9]*|Http[0-9]*|Ssl[0-9]*)\]' "$LOG" \
    | sort | uniq -c | sort -rn || echo "  (no Np/Net log lines found at all)"

hdr "NpMatching2 — room / session lifecycle"
grep -aE 'NpMatching2' "$LOG" \
    | grep -aiE 'CreateJoinRoom|JoinRoom|LeaveRoom|SearchRoom|SetUserInfo|ContextStart|RoomMemberUpdate|SignalingInfo|GetRoom' \
    | head -40 || echo "  (none)"

hdr "Signaling / peer resolution (the P2P handshake)"
grep -aE 'NpSignaling|RequestSignalingInfos|hole|punch|peer' "$LOG" | head -40 || echo "  (none)"

hdr "Outbound HTTP (session server traffic)"
grep -aiE 'Lib\.Http|sceHttp' "$LOG" \
    | grep -aoE 'https?://[A-Za-z0-9._~:/?#@!$&*+,;=%-]+' \
    | sort | uniq -c | sort -rn | head -30 || echo "  (none)"

hdr "Socket creation (shadPS4 logs these as sys_socketex, NOT sceNetSocket)"
grep -aE 'sys_socketex|sys_socketclose' "$LOG" | head -20 || echo "  (none)"

hdr "P2P DATA PATH -- did any packet actually move?"
grep -aE 'P2P send|P2P recv|P2P socket bound|P2P transport ready' "$LOG" | head -40 \
    || echo "  (none -- needs the instrumented build)"

hdr "Unimplemented / stubbed calls hit during the run"
grep -aiE 'unimplemented|not implemented|UNREACHABLE|todo|stub' "$LOG" \
    | sed -E 's/^.*\] //' | sort | uniq -c | sort -rn | head -30 || echo "  (none)"

hdr "Errors and failures"
grep -aE '\[(error|critical)\]|SCE_NP_.*ERROR|returned 0x8' "$LOG" \
    | sed -E 's/^.*\] //' | sort | uniq -c | sort -rn | head -30 || echo "  (none)"

# --- Verdict -------------------------------------------------------------
SENDS=$(count 'P2P send #')
RECVS=$(count 'P2P recv #')
SENDFAIL=$(count 'P2P send FAILED')
P2PSTUB=$(count 'p2p_sockets\.cpp.*STUBBED')
PORT=$(grep -aoE 'p2p_port=[0-9]+' "$LOG" | tail -1 || true)
HTTP=$(count 'Lib\.Http|sceHttp')

hdr "Verdict"
printf '  p2p_port          : %s\n' "${PORT:-not reported}"
printf '  P2P stub errors   : %s   (want 0)\n' "$P2PSTUB"
printf '  P2P sends logged  : %s\n' "$SENDS"
printf '  P2P recvs logged  : %s\n' "$RECVS"
printf '  P2P send failures : %s\n' "$SENDFAIL"
printf '  HTTP lines        : %s\n' "$HTTP"
echo

# The question this run answers is narrow: can the transport carry traffic?
# Co-op cannot work regardless until the session server brokers a summon, so a
# healthy transport with zero traffic is the expected good outcome for now.
if [[ "$P2PSTUB" -gt 0 ]]; then
    echo "  => Transport still STUBBED. The patched build is not the one that ran."
    echo "     Check BBLauncher is pointed at the patched AppImage."
elif [[ "$RECVS" -gt 0 ]]; then
    echo "  => Packets received from a peer. The transport is carrying traffic --"
    echo "     this is the strongest possible signal at this stage."
elif [[ "$SENDS" -gt 0 ]]; then
    echo "  => Sending but nothing received. Expected while no peer exists."
    echo "     Confirms the socket works; the missing half is a peer to talk to."
elif [[ "$PORT" == "p2p_port=0" || -z "$PORT" ]]; then
    echo "  => Transport not initialised (p2p_port unset or 0)."
else
    echo "  => Transport is up ($PORT) but no datagrams were sent."
    echo "     Expected: the session server never brokered a summon, so the game"
    echo "     had no peer address to send to. Next blocker is server-side."
fi
echo
