#!/usr/bin/env python3
"""
Bloodborne session server: passthrough with summon brokering.

Everything is forwarded to the real server (so blood messages, ghosts, chalices
and notices keep working untouched) EXCEPT the summon matchmaking endpoints,
which are answered locally. That lets two of your own clients find each other
without needing the upstream server to implement co-op.

Why this shape: the messages after a match -- SummonDataSummon, CreateSession,
and the P2P handshake -- have never been observed, because upstream never
matches anyone, so the game never sends them. Brokering a match locally is what
makes the game emit them. The server is the instrument for discovering the rest
of the protocol, not just an endpoint.

Protocol facts this is built on, all observed directly:
  /summon_messenger/create   SummonDataCreateRequest   guest advertises
  /summon_messenger/get      SummonDataGetListRequest  host searches
  /summon_messenger/delete   SummonDataRemoveRequest   guest retracts
  /summon_messenger/request  SummonDataSummonRequest   host took a sign (ack only)
  Matching window is +/-20 levels (ss.info SummonDataCoopMatchingLevel*Abs1).
  Create repeats every 30s, GetList every 35s (ss.info intervals).

What this server is and is not. Per Metr1k (Hunter's Dream), the session server
stores SOS signs and returns them when asked, and does nothing else -- it does
not broker the connection. Once the host accepts a sign, everything else happens
elsewhere: the host hands the guest's NPID (carried inside the SummonData blob)
to the signaling library, shadNet resolves it to an ip:port, the host opens a
matching2 room and pushes the room data to the guest over that P2P channel, and
the guest joins the room. So the entire contract here is: return a list entry
the game finds credible, with an NPID shadNet can resolve.

"Credible" is a stricter requirement than it looks. The real server base64-
decodes each sign and reads MatchingLevel and CharaId out of the SOSSignMan
struct rather than trusting the advertiser's JSON, so a list entry is a
projection of the blob, not an echo of the request. See the layout notes below.

Usage:
    ./bb-server.py                      # broker summons, forward the rest
    ./bb-server.py --strict             # apply type/level/area/distance filters
    ./bb-server.py --no-forward         # answer everything locally (offline)
"""

import argparse
import base64
import copy
import datetime
import http.client
import http.server
import json
import math
import os
import socketserver
import struct
import sys
import threading
import time
import uuid
import zlib

LOCK = threading.Lock()
ARGS = None
LOGFILE = None
SEQ = 0

# npid -> {"body": <create request>, "ts": <epoch>, "info": <decoded blob>}
SIGNS = {}
SIGNS_LOCK = threading.Lock()

# A sign is refreshed every 30s by the client; drop it if we miss two refreshes.
SIGN_TTL = 75.0

# The nine fields of a SummonDataGetListResponse entry, from a real response.
# --observe checks live upstream replies against this set: anything extra is a
# field we are failing to send, anything missing is one we invented.
REFERENCE_KEYS = (
    "SummonId", "UserId", "CharaId", "SummonData", "SummonDataVersion",
    "MatchingLevel", "Region", "RegionFlag", "NatType",
)

# Server-assigned sign identifiers. The host echoes one back in
# SummonDataSummonRequest to say which sign it picked, so it has to be stable
# for a given advertiser rather than regenerated per GetList poll.
SUMMON_IDS = {}
SUMMON_ID_NEXT = [7000]


def next_summon_id(key):
    with SIGNS_LOCK:
        if key not in SUMMON_IDS:
            SUMMON_ID_NEXT[0] += 1
            SUMMON_IDS[key] = SUMMON_ID_NEXT[0]
        return SUMMON_IDS[key]


# ---------------------------------------------------------------------------
# The SummonData blob
# ---------------------------------------------------------------------------
#
# 224 bytes, little-endian. Layout established by diffing our own captured sign
# against a real Hunter's Dream response for a different player: only thirteen
# byte-runs differ between the two, which pins the variable fields exactly.
#
#   0x00  4 x u32   1,000,000 each
#   0x10  16 bytes  0xff filler
#   0x20  4 x u32   equipment ids 230000 / 231000 / 232000 / 233000
#   0x40  16 bytes  character name, null-padded
#   0x50  u32       per-session nonce (differs per player, meaning unknown)
#   0x54  f32       2.0
#   0x58  u32       0x118
#   0x5c  3 x f32   world position X, Y, Z
#   0x68  f32       facing angle
#   0x6c  u32       AreaRegionId (241010 -- identical in both samples, and equal
#                   to the AreaRegionId our client puts in its JSON request)
#   0x70  u32       MatchingLevel
#   0x7d  bytes     PSN online id (NPID), null-padded
#   0xd8  u64       CharaId
#
# The last three matter most. MatchingLevel and CharaId are *mirrored* into the
# JSON list entry: the real server decodes the base64 and reads them out with
# the same SOSSignMan struct the game uses, rather than trusting the numbers the
# advertiser put in its request. So an entry whose JSON disagrees with its own
# blob is self-contradictory -- a state the real server can never produce, and
# a plausible reason for the game to discard a candidate silently.
#
# The NPID is the field the whole session ultimately turns on: it is the only
# routing information in the sign (there is no address anywhere in these 224
# bytes), and it is what the host feeds to the signaling library for shadNet to
# resolve into an ip:port.

BLOB_LEN = 224
OFF_NAME = 0x40
LEN_NAME = 16
OFF_POS = 0x5C
OFF_FACING = 0x68
OFF_AREA = 0x6C
OFF_LEVEL = 0x70
OFF_NPID = 0x7D
END_NPID = 0xCC
OFF_CHARA_ID = 0xD8


def _cstr(buf, start, end):
    chunk = buf[start:end]
    z = chunk.find(b"\0")
    return (chunk[:z] if z >= 0 else chunk).decode("utf-8", "replace")


def decode_summon_data(b64):
    """Read the fields the game reads. Returns None if it does not parse.

    Failure is deliberately soft: a sign we cannot decode should still be
    brokered, just without the extra cross-checks. Refusing to relay a sign
    because our own parser disliked it would be the worst outcome.
    """
    try:
        blob = base64.b64decode(b64 or "")
    except Exception:
        return None
    if len(blob) < BLOB_LEN:
        return None
    x, y, z = struct.unpack_from("<3f", blob, OFF_POS)
    return {
        "name": _cstr(blob, OFF_NAME, OFF_NAME + LEN_NAME),
        "npid": _cstr(blob, OFF_NPID, END_NPID),
        "pos": (x, y, z),
        "facing": struct.unpack_from("<f", blob, OFF_FACING)[0],
        "area": struct.unpack_from("<I", blob, OFF_AREA)[0],
        "level": struct.unpack_from("<I", blob, OFF_LEVEL)[0],
        "chara_id": struct.unpack_from("<Q", blob, OFF_CHARA_ID)[0],
    }


def describe(info):
    if not info:
        return "blob did not parse"
    x, y, z = info["pos"]
    return (f"char='{info['name']}' npid='{info['npid']}' lvl={info['level']} "
            f"chara={info['chara_id']:#x} area={info['area']} "
            f"pos=({x:.1f},{y:.1f},{z:.1f})")


def patch_summon_data(b64, name=None, npid=None, chara_id=None, pos_delta=None):
    """Rewrite fields in place, preserving the 224-byte length exactly.

    Fixed offsets rather than search-and-replace: substring replacement only
    works when the new value is the same length as the old one, which silently
    constrains what you can test.
    """
    try:
        blob = bytearray(base64.b64decode(b64 or ""))
    except Exception:
        return b64, "blob did not decode; left alone"
    if len(blob) < BLOB_LEN:
        return b64, "blob too short; left alone"

    notes = []
    if name is not None:
        blob[OFF_NAME:OFF_NAME + LEN_NAME] = \
            name.encode()[:LEN_NAME].ljust(LEN_NAME, b"\0")
        notes.append(f"name='{name}'")
    if npid is not None:
        width = END_NPID - OFF_NPID
        blob[OFF_NPID:END_NPID] = npid.encode()[:width].ljust(width, b"\0")
        notes.append(f"npid='{npid}'")
    if chara_id is not None:
        struct.pack_into("<Q", blob, OFF_CHARA_ID, chara_id)
        notes.append(f"chara={chara_id:#x}")
    if pos_delta:
        x, y, z = struct.unpack_from("<3f", blob, OFF_POS)
        struct.pack_into("<3f", blob, OFF_POS, x + pos_delta, y, z + pos_delta)
        notes.append(f"pos{pos_delta:+g}")

    assert len(blob) == BLOB_LEN, "patch changed blob length"
    return base64.b64encode(bytes(blob)).decode(), ", ".join(notes) or "unchanged"


def identity(body, info=None):
    """Stable storage key for one advertiser.

    Keyed on the NPID from the blob, not on UserId. UserId is the Hunter's Dream
    account id and two clients signed into the same account would share it --
    each refresh would then overwrite the other's sign and the store would never
    hold more than one. The NPID is per shadPS4 profile, so it always differs
    between the two machines.
    """
    if info is None:
        info = decode_summon_data(body.get("SummonData"))
    if info and info["npid"]:
        return info["npid"]
    return f"user:{body.get('UserId')}"


def self_key(body):
    """Identity as the game itself can see it, on either message shape.

    GetList requests carry no SummonData blob -- only UserId and CharaId appear
    in both the advertisement and the search -- so this pair is the only thing
    self-exclusion can compare. CharaId alone will not do: our captures show the
    sentinel 0x8000000000000000, which both clients can produce.
    """
    return (body.get("UserId"), body.get("CharaId"))

HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade",
}


def stamp():
    return datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]


def emit(text):
    with LOCK:
        sys.stdout.write(text + "\n")
        sys.stdout.flush()
        if LOGFILE:
            LOGFILE.write(text + "\n")
            LOGFILE.flush()


def prune_signs():
    now = time.time()
    with SIGNS_LOCK:
        dead = [k for k, v in SIGNS.items() if now - v["ts"] > SIGN_TTL]
        for k in dead:
            del SIGNS[k]
            emit(f"    [broker] sign expired: user {k}")


# ---------------------------------------------------------------------------
# --observe: learn the contract from the real server instead of guessing it
# ---------------------------------------------------------------------------

OBSERVED = []


def report_upstream(parsed):
    """Dump an upstream summon response in full, and check it against our model.

    Everything we believe about the response shape came from one reference
    snippet and a two-sample blob diff. A live non-empty SummonDataGetListResponse
    from real players is the only thing that can actually confirm it -- or show
    which offsets we got lucky on. So print the whole body untruncated, decode
    every blob, and state explicitly whether the JSON agrees with the bytes.
    """
    msgid = parsed.get("MessageId") or ""
    if not msgid.startswith("SummonData"):
        return

    entries = parsed.get("SummonDataList") or []
    emit("\n" + "~" * 78)
    emit(f"~~~ UPSTREAM {msgid}: {len(entries)} entr{'y' if len(entries) == 1 else 'ies'}")
    if not entries:
        emit("~~~ Empty. Nobody else has a sign up in your bracket right now --")
        emit("~~~ this tells us nothing new. Try a common level in a busy area.")
        emit("~" * 78 + "\n")
        return

    emit(json.dumps(parsed, indent=2))
    for i, e in enumerate(entries):
        emit(f"\n--- entry {i} ---")
        emit(f"    keys: {sorted(e)}")
        extra = sorted(set(e) - set(REFERENCE_KEYS))
        missing = sorted(set(REFERENCE_KEYS) - set(e))
        if extra:
            emit(f"    !! fields we do NOT emit: {extra}")
        if missing:
            emit(f"    !! fields we emit but upstream does not: {missing}")

        info = decode_summon_data(e.get("SummonData"))
        if not info:
            emit("    !! blob did not decode at our assumed 224-byte layout")
            continue
        emit(f"    blob: {describe(info)}")
        for jkey, bkey in (("CharaId", "chara_id"), ("MatchingLevel", "level")):
            if jkey in e:
                ok = "OK" if e[jkey] == info[bkey] else "MISMATCH"
                emit(f"    {ok}: JSON {jkey}={e[jkey]} vs blob {info[bkey]}")

    OBSERVED.append(parsed)
    path = os.path.join(ARGS.outdir, "upstream-summon-responses.json")
    try:
        with open(path, "w") as fh:
            json.dump(OBSERVED, fh, indent=2)
        emit(f"\n~~~ saved {len(OBSERVED)} response(s) to {path}")
    except Exception as exc:
        emit(f"\n~~~ could not save: {exc}")
    emit("~" * 78 + "\n")


# ---------------------------------------------------------------------------
# Summon brokering
# ---------------------------------------------------------------------------

def handle_create(body):
    """Guest rings the Small Resonant Bell: remember that they are available."""
    info = decode_summon_data(body.get("SummonData"))
    key = identity(body, info)
    with SIGNS_LOCK:
        fresh = key not in SIGNS
        SIGNS[key] = {"body": body, "ts": time.time(), "info": info}
        total = len(SIGNS)

    emit(f"    [broker] {'NEW' if fresh else 'refresh'} sign '{key}' "
         f"user={body.get('UserId')} type={body.get('SummonType')} ({total} active)")
    # Unified transcript tag: grep '[COOP]' across this log + shadNet + client logs
    # to reconstruct the whole summon in order. GUEST made itself available here.
    emit(f"    [COOP] sign-create key='{key}' user={body.get('UserId')} "
         f"type={body.get('SummonType')} npid={(info or {}).get('npid') or '<none>'}")
    if fresh:
        emit(f"    [broker]   {describe(info)}")
        if info and info["chara_id"] != body.get("CharaId"):
            emit(f"    [broker]   note: blob CharaId {info['chara_id']:#x} != "
                 f"request CharaId {body.get('CharaId')}; the blob wins")
        if info and not info["npid"]:
            emit("    [broker]   !! no NPID in blob -- shadNet cannot resolve this "
                 "peer, so signaling will fail even if the match is offered")
    return {"ResKind": 0, "MessageId": "SummonDataCreateResponse"}


def handle_remove(body):
    key = identity(body)
    with SIGNS_LOCK:
        existed = SIGNS.pop(key, None) is not None
        if not existed:
            # A retraction can arrive after the sign expired, or from a client
            # whose blob we never parsed. Fall back to the account id -- but
            # only when it is unambiguous, or we would drop the other player.
            uid = body.get("UserId")
            hits = [k for k, v in SIGNS.items() if v["body"].get("UserId") == uid]
            if len(hits) == 1:
                key = hits[0]
                del SIGNS[key]
                existed = True
    emit(f"    [broker] sign removed: '{key}'" + ("" if existed else " (none held)"))
    return {"ResKind": 0, "MessageId": "SummonDataRemoveResponse"}


def eligible(seeker, seeker_info, sign_body, sign_info, wanted_types):
    """Whether a stored sign should be offered to this seeker.

    Self-exclusion and the SummonType filter always apply -- offering a sign of
    the wrong type is something the real server never does, and the client would
    only discard it, muddying the diagnosis. The distance/level/area rules are
    --strict only: for a bring-up you want the match to happen so the follow-on
    messages appear, not to faithfully reproduce FromSoft's filtering.
    """
    if self_key(sign_body) == self_key(seeker) and not ARGS.allow_self:
        return False, "self (same UserId+CharaId)"

    stype = sign_body.get("SummonType")
    if wanted_types and stype not in wanted_types:
        return False, f"SummonType {stype} not among requested {sorted(wanted_types)}"

    if not ARGS.strict:
        return True, "permissive"

    lvl_a = (seeker_info or {}).get("level") or seeker.get("MatchingLevel") or 0
    lvl_b = (sign_info or {}).get("level") or sign_body.get("MatchingLevel") or 0
    if abs(lvl_a - lvl_b) > 20:
        return False, f"level {lvl_b} outside {lvl_a}+/-20"

    area_a = seeker.get("AreaId")
    area_b = sign_body.get("AreaId")
    if area_a != area_b:
        return False, f"AreaId {area_b} != {area_a}"

    # The seeker has no blob of its own -- GetList carries loose PosX/Y/Z
    # integers instead -- so its position has to come from the JSON. Rounded to
    # whole units by the client, which is plenty against a 100-unit threshold.
    thresh = seeker.get("DistanceThreshold")
    here = (seeker_info or {}).get("pos")
    if here is None and all(seeker.get(k) is not None for k in ("PosX", "PosY", "PosZ")):
        here = (seeker["PosX"], seeker["PosY"], seeker["PosZ"])
    if thresh and here and sign_info:
        dist = math.dist(here, sign_info["pos"])
        if dist > thresh:
            return False, f"distance {dist:.0f} > {thresh}"
    return True, "match"


def build_entry(sign_body, sign_info, summon_id, user_id):
    """Construct one SummonDataList element.

    Exactly nine fields -- no more. This matches a real response:

      {"SummonId":7840,"UserId":31,"CharaId":13,"SummonData":"<b64>",
       "SummonDataVersion":3,"MatchingLevel":10,"Region":1,"RegionFlag":1,
       "NatType":2}

    Earlier attempts echoed the whole Create request back (28 fields, including
    AreaId, PosX/Y/Z, SessionId, SummonType, the NaturalEnemy_* set and the
    UnlockFlagList variants). The client parsed that and did nothing with it.
    The entry is a small projection, not an echo -- and it carries a
    server-assigned SummonId, which nothing we sent ever had.

    CharaId and MatchingLevel come from the *decoded blob*, not from the create
    request: the real server base64-decodes the sign and reads them out of the
    SOSSignMan struct. Position and area are absent for the same reason -- the
    game reads those from the blob too, which is why it must pass through
    byte-for-byte.
    """
    if ARGS.nat_type is not None:
        nat = ARGS.nat_type
    else:
        nat = sign_body.get("NatType", 0)
    return {
        "SummonId": summon_id,
        "UserId": user_id,
        "CharaId": (sign_info or {}).get("chara_id") or sign_body.get("CharaId"),
        "SummonData": sign_body.get("SummonData"),
        "SummonDataVersion": sign_body.get("SummonDataVersion", 3),
        "MatchingLevel": (sign_info or {}).get("level") or sign_body.get("MatchingLevel"),
        "Region": sign_body.get("Region", 1),
        "RegionFlag": sign_body.get("RegionFlag", 1),
        "NatType": nat,
    }


def entry_user_id(sign_body, key, seeker):
    """The UserId to advertise for this sign.

    Normally the advertiser's own account id. But if both clients signed into
    the same Hunter's Dream account they carry the same UserId, and the game
    would be looking at a candidate that shares its own account. Substitute a
    stable synthetic id derived from the NPID so the two are distinguishable --
    the field is only an identifier to the client, and nothing downstream
    resolves an address from it (that is the NPID's job).
    """
    uid = sign_body.get("UserId")
    if uid != seeker.get("UserId"):
        return uid
    synth = 900000 + (zlib.crc32(key.encode()) % 90000)
    emit(f"    [broker]   !! '{key}' shares UserId {uid} with the seeker -- both "
         f"machines are signed into the same account. Advertising as {synth}.")
    return synth


def handle_getlist(body):
    """Host rings the Beckoning Bell: hand back whoever is advertising."""
    prune_signs()
    seeker = body.get("UserId")
    limit = body.get("GetMaxCount") or 20

    # The host asks per summon type, each with its own quota.
    quota, used = {}, {}
    for spec in body.get("SummonTypeList") or []:
        st = spec.get("SummonType")
        quota[st] = spec.get("GetLimitCount") or limit
        used[st] = 0

    with SIGNS_LOCK:
        candidates = [(k, v["body"], v["info"]) for k, v in SIGNS.items()]

    out, rejected = [], []
    for key, cbody, cinfo in candidates:
        ok, why = eligible(body, None, cbody, cinfo, quota)
        if not ok:
            rejected.append(f"'{key}': {why}")
            continue
        st = cbody.get("SummonType")
        if st in quota and used[st] >= quota[st]:
            rejected.append(f"'{key}': type {st} quota ({quota[st]}) already filled")
            continue
        used[st] = used.get(st, 0) + 1
        out.append(build_entry(cbody, cinfo,
                               next_summon_id(key),
                               entry_user_id(cbody, key, body)))
        emit(f"    [broker]   offering '{key}' as SummonId {out[-1]['SummonId']} "
             f"UserId {out[-1]['UserId']} CharaId {out[-1]['CharaId']} "
             f"lvl {out[-1]['MatchingLevel']}")
        if len(out) >= limit:
            break

    # HOST searched; this is what it got back. Zero here while a guest sign is held
    # means the eligible()/quota filter rejected it -- see the rejected reasons above.
    emit(f"    [COOP] getlist seeker={seeker} returned={len(out)} "
         f"heldSigns={len(candidates)}")
    if out:
        emit(f"    [broker] *** returning {len(out)} sign(s) to user {seeker} ***")
    else:
        detail = "; ".join(rejected) if rejected else "no signs held"
        emit(f"    [broker] no match for user {seeker} ({detail})")
        if any("self (" in r for r in rejected):
            emit("    [broker] !! a candidate was indistinguishable from the seeker: "
                 "same UserId AND same CharaId. That means both machines logged into "
                 "the same upstream account and both carry the CharaId sentinel, so "
                 "nothing in either message tells them apart. Give each machine its "
                 "own shadPS4 profile (which gets its own user_id), or pass "
                 "--allow-self to broker the match anyway and see what the game does.")

    return {
        "SummonDataList": out,
        "ResKind": 0,
        "MessageId": "SummonDataGetListResponse",
    }


def disguise_peer(peer):
    """Turn a captured sign into a plausibly different player.

    A sign replayed verbatim is the capturing player's OWN character, and the
    game filters itself out of its own summon list -- correct behaviour that
    looks exactly like a rejected entry. Every field tying the sign to that
    identity has to change, in the JSON *and* in the blob, consistently: the
    server derives CharaId from the blob, so changing only the JSON copy
    produces an entry that contradicts itself.
    """
    peer = copy.deepcopy(peer)
    name = ARGS.fake_peer_name
    chara = ARGS.fake_peer_chara

    peer["UserId"] = 999999
    peer["CharaId"] = chara
    peer["SessionId"] = str(uuid.uuid4())
    peer["SummonData"], notes = patch_summon_data(
        peer["SummonData"], name=name, npid=name, chara_id=chara)

    emit(f"    [disguise] JSON UserId/CharaId/SessionId replaced; blob: {notes}")
    emit("    [disguise] this peer is not a real client -- a summon attempt against "
         "it will reach signaling and then fail there, which is still a useful result")
    return peer


def handle_summon(body):
    """Host picked a guest and is telling the server which sign it took.

    Endpoint is /summon_messenger/request -- confirmed from eboot.bin
    ("SummonDataSummon:%hS/summon_messenger/request"), NOT /summon_messenger/summon.

    Per Metr1k this is only an acknowledgement: the session server stores SOS
    signs and returns them, and does nothing else. It does not broker anything.
    Everything after this point happens off this server entirely -- the host
    hands the guest's NPID to the signaling library, shadNet resolves it to an
    ip:port, the host opens a matching2 room and pushes the room data to the
    guest over that P2P channel, and the guest joins the room.

    So reaching this handler means our job is done and the remaining failure
    modes are all in shadNet and the P2P sockets. The plain ack below matches
    every other response shape observed; if the game stalls immediately after
    this, this reply is the first thing to suspect.
    """
    emit("\n" + "!" * 78)
    # The pivot: host committed to a specific guest. After this, watch shadNet's
    # [COOP] RequestSignalingInfos + CreateRoom, then the guest's [COOP] MmSearchRoom.
    emit(f"    [COOP] summon-request user={body.get('UserId')} "
         f"summonId={body.get('SummonId')} tookNpid={body.get('Npid') or '<see body>'}")
    emit("!!! SummonDataSummonRequest RECEIVED -- the host accepted a sign.")
    emit("!!! Watch shadNet now for a signaling")
    emit("!!! lookup of the guest's NPID, then a matching2 room.")
    emit("!!! Full body:")
    emit(json.dumps(body, indent=2))
    emit("!" * 78 + "\n")
    return {"ResKind": 0, "MessageId": "SummonDataSummonResponse"}


HANDLERS = {
    "SummonDataCreateRequest": handle_create,
    "SummonDataGetListRequest": handle_getlist,
    "SummonDataRemoveRequest": handle_remove,
    "SummonDataSummonRequest": handle_summon,
}

# Messages we know exist (from the ss.info endpoint list and the PlayLog state
# machine) but have never seen on the wire. If one shows up, a match worked and
# we are into genuinely new protocol -- say so unmissably.
UNCHARTED = (
    "SummonDataSummon", "CreateSession", "JoinSession", "HandShake", "P2P",
)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        pass

    def respond_json(self, obj):
        payload = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("sp-res-kind", "0")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def patch_ssinfo(self, data):
        """Turn on the game's own matchmaking diagnostics.

        ss.info is base64-encoded XML carrying per-event logging flags, and
        Playlog_MatchingLog / Playlog_MatchingFailureLog ship disabled. The game
        already knows why it rejected a summon candidate; these flags are what
        make it say so, via the api_MultiPlayNetError endpoint. Since the config
        passes through us, we can enable them -- far better than inferring the
        reason from the outside.
        """
        try:
            xml = base64.b64decode(data).decode("utf-8", "replace")
        except Exception:
            return data
        if "Playlog_MatchingFailureLog" not in xml:
            return data

        flipped = []
        for flag in ("Playlog_MatchingLog1", "Playlog_MatchingFailureLog1",
                     "Playlog_SeriousPlaylogInfo1", "Playlog_CommonInfo1"):
            before = f"<{flag}>0</{flag}>"
            if before in xml:
                xml = xml.replace(before, f"<{flag}>1</{flag}>")
                flipped.append(flag)
        if flipped:
            emit(f"    [ssinfo] enabled: {', '.join(flipped)}")
        return base64.b64encode(xml.encode()).decode().encode()

    def forward(self, seq, body, port):
        fwd = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
        up_port = ARGS.upstream_port or port
        fwd["Host"] = f"{ARGS.upstream}:{up_port}"
        try:
            conn = http.client.HTTPConnection(ARGS.upstream, up_port, timeout=ARGS.timeout)
            conn.request(self.command, self.path, body=body, headers=fwd)
            resp = conn.getresponse()
            data = resp.read()
        except Exception as exc:
            emit(f"[{stamp()}] #{seq} !!! upstream error: {exc}")
            self.send_response(502)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        try:
            parsed_data = json.loads(data.decode("utf-8"))
        except Exception:
            parsed_data = None

        # Kept out of the try below on purpose: a bug in the observer must not be
        # swallowed by that bare except, which would also silently skip the
        # injection underneath it.
        if parsed_data is not None and ARGS.observe:
            try:
                report_upstream(parsed_data)
            except Exception as exc:
                emit(f"    [observe] !! report failed: {exc!r}")

        # MY CUSTOM CODE to edit the login message
        # =====================================================================
        try:
            # Check if this is the target LoginResponse message
            if parsed_data is not None and parsed_data.get("MessageId") == "LoginResponse":
                
                # 1. Define your custom message
                custom_message = "\nSeek paleblood to transcend the hunt\n\n\n\nCustom server made by William (not really)\n\nHopefully coop will work today お願い"
                
                # 2. Base64 encode it (the game client expects this format)
                # We encode to bytes, b64 encode it, then decode back to a string for JSON
                encoded_message = base64.b64encode(custom_message.encode("utf-8")).decode("utf-8")
                
                # 3. Swap the old WarningMessage out for the new one
                parsed_data["WarningMessage"] = encoded_message
                
                # 4. Re-encode the JSON dictionary back into raw bytes for transmission
                data = json.dumps(parsed_data).encode("utf-8")
                
                emit("    [injector] Successfully replaced WarningMessage in LoginResponse")
        except Exception:
            # If the response isn't JSON, just let it pass through normally
            pass
        # =====================================================================
        
        if self.path.endswith("ss.info") and not ARGS.no_patch_ssinfo:
            data = self.patch_ssinfo(data)

        emit(f"[{stamp()}] #{seq} <-- {resp.status} (forwarded, {len(data)} bytes)")
        if data and len(data) < 4096:
            emit(f"    {data[:2000].decode('utf-8', 'replace')}")
        self.send_response(resp.status, resp.reason)
        for k, v in resp.getheaders():
            if k.lower() not in HOP_BY_HOP and k.lower() != "content-length":
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        conn.close()

    def proxy(self):
        global SEQ
        with LOCK:
            SEQ += 1
            seq = SEQ

        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        port = self.server.server_address[1]

        parsed, msgid = None, None
        try:
            parsed = json.loads(raw.decode("utf-8"))
            msgid = parsed.get("MessageId")
        except Exception:
            pass

        emit(f"\n{'=' * 78}\n[{stamp()}] #{seq} --> {self.command} {self.path}  [{msgid or 'non-JSON'}]")
        if raw and ARGS.verbose:
            emit(f"    {raw[:2000].decode('utf-8', 'replace')}")

        if msgid and any(u in msgid for u in UNCHARTED):
            emit("\n" + "*" * 78)
            emit(f"*** UNCHARTED MESSAGE: {msgid}")
            emit("*** A match progressed further than we have ever observed.")
            emit("*** Full body follows -- this is new protocol.")
            emit("*" * 78)
            emit(raw.decode("utf-8", "replace"))
            emit("*" * 78 + "\n")

        # In observe mode the summon endpoints go upstream like everything else:
        # the point is to see what the real server says, not what we would say.
        handler = None if ARGS.observe else HANDLERS.get(msgid)
        if handler and parsed is not None:
            reply = handler(parsed)
            emit(f"[{stamp()}] #{seq} <-- {reply['MessageId']} (brokered locally)")
            self.respond_json(reply)
            return

        if ARGS.no_forward:
            emit(f"[{stamp()}] #{seq} <-- 200 empty (offline mode, no handler)")
            self.respond_json({"ResKind": 0})
            return

        self.forward(seq, raw, port)

    do_GET = do_POST = do_ = do_DELETE = do_HEAD = do_PATCH = do_OPTIONS = proxy


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    global ARGS, LOGFILE
    ap = argparse.ArgumentParser()
    ap.add_argument("--upstream", default="thehuntersdream.com")
    ap.add_argument("--upstream-port", type=int, default=0)
    ap.add_argument("--ports", nargs="+", type=int, default=[18671, 20443])
    ap.add_argument("--outdir", default=".")
    ap.add_argument("--timeout", type=float, default=15.0)
    ap.add_argument("--strict", action="store_true",
                    help="enforce level/area matching rules")
    ap.add_argument("--observe", action="store_true",
                    help="do not broker anything locally -- forward the summon "
                         "endpoints upstream too and dump the real server's "
                         "replies, decoding every blob. Use this to confirm the "
                         "response contract against live players.")
    ap.add_argument("--no-forward", action="store_true",
                    help="never contact upstream (offline experiments)")
    ap.add_argument("--verbose", action="store_true", help="log full request bodies")
    ap.add_argument("--no-patch-ssinfo", action="store_true",
                    help="do not enable the game's matchmaking failure logging")
    ap.add_argument("--allow-self", action="store_true",
                    help="offer a sign back to a seeker that looks like its own "
                         "(use only if both machines are stuck on one account)")
    ap.add_argument("--nat-type", type=int, default=None, metavar="N",
                    help="override the advertised NatType (our clients send 0; a "
                         "real captured response carried 2)")
    ap.add_argument(
        "--fake-peer",
        metavar="FILE",
        help="inject a captured SummonDataCreateRequest as a permanent sign, so a "
             "single client can be offered a match with no second machine present",
    )
    ap.add_argument("--fake-peer-name", default="HunterTwo",
                    help="character name and NPID to give the fake peer")
    ap.add_argument("--fake-peer-chara", type=lambda s: int(s, 0), default=13,
                    help="CharaId for the fake peer, written to both the JSON and "
                         "blob (default 13, as seen in a real response)")
    ARGS = ap.parse_args()

    os.makedirs(ARGS.outdir, exist_ok=True)
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    logpath = os.path.join(ARGS.outdir, f"server-{ts}.log")
    LOGFILE = open(logpath, "w")

    emit(f"log       : {logpath}")
    emit(f"upstream  : {'(none - offline)' if ARGS.no_forward else ARGS.upstream}")
    if ARGS.observe:
        emit("mode      : OBSERVE -- brokering disabled, everything forwarded")
        emit("            upstream summon replies dumped and blob-checked")
    else:
        emit(f"matching  : "
             f"{'strict (level +/-20, same area)' if ARGS.strict else 'permissive'}")
        emit("brokering : SummonDataCreate / GetList / Remove")

    if ARGS.fake_peer:
        with open(ARGS.fake_peer) as fh:
            peer = json.load(fh)
        peer = disguise_peer(peer)
        info = decode_summon_data(peer.get("SummonData"))
        key = identity(peer, info)
        SIGNS[key] = {"body": peer, "ts": time.time() + 10 ** 9, "info": info}
        emit(f"fake peer : injected as '{key}' -- {describe(info)}")
        emit("            ring the Beckoning Bell -- this sign will be offered to you")

    for port in ARGS.ports:
        try:
            srv = Server(("0.0.0.0", port), Handler)
        except OSError as exc:
            emit(f"!! cannot bind 0.0.0.0:{port}: {exc}")
            return 1
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        emit(f"listening : 0.0.0.0:{port}")

    emit("\nBound on 0.0.0.0 so a second machine can reach this one.")
    emit("On BOTH Decks, point host_overrides.json at whichever box runs this:\n")
    emit('  {')
    emit('    "ss4.scej-network.jp": "http://<this-machine-ip>",')
    emit(f'    "{ARGS.upstream}": "http://<this-machine-ip>"')
    emit('  }')
    emit("\nThen: guest rings the Small Resonant Bell, host rings the Beckoning Bell.")
    emit("Watch for '*** returning N sign(s)' followed by an UNCHARTED MESSAGE.\n")

    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        emit(f"\nstopped. log: {logpath}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
