# Bloodborne co-op on shadPS4 — research notes & capture tooling

Goal: peer-to-peer co-op between two PCs running Bloodborne under modified shadPS4 for mac and steamdeck.

### The two server-side channels (these are separate — don't conflate them)

| | ShadNet | Bloodborne session server |
|---|---|---|
| Role | NpMatching2 rooms, peer address resolution | Summon signs, messages, bloodstains, ghosts |
| Transport | TCP, protobuf, 15-byte header | HTTP |
| Config | `shadnet_server` = `srv.shadps4.net:31313` | `host_overrides.json` |
| Status | Implemented, public server exists | Passthrough to The Hunters Dream and implemented SoSSignMan for matchmaking|

`host_overrides.json` **only affects HTTP** — it is read at
`src/core/libraries/network/http.cpp:335` and nowhere else. It redirects
FromSoft's `https://ss4.scej-network.jp:20443` to a replacement server. That is
the Hunter's Dream mechanism, and co-op is the part nobody has published.

### How Bloodborne Matchmaking seems to work

1. The session server hands the host a list of SOS signs. The guest's NPID is
   inside the base64 `SummonData` blob — there is no address anywhere in it.
2. The host takes one and sends `SummonDataSummonRequest`. **This is only an
   acknowledgement**; the server does nothing with it.
3. The host passes the guest's NPID to the signaling library. ShadNet resolves
   it to an external ip:port (or a relay).
4. Simultaneously the host opens an NpMatching2 room and pushes the room data
   directly to the guest over that P2P channel.
5. The guest parses the room data and calls matching2 to join — a second
   handshake.
6. The summon happens.

We are stuck at steps 4-6. It looks like we are not pushing the room data in a way the bloodborne code accepts as it instantly rejects the request. The issue is probably an issue with our P2P implementation in shadPS4.

## bb-server.py — the sign store

Passthrough proxy for `thehuntersdream.com`, except the four
`/summon_messenger/*` endpoints, which are answered locally so two of our own
clients can find each other.

### The response contract

A `SummonDataGetListResponse` entry has **exactly nine fields**, matching a real
captured response:

```json
{"SummonId":7840,"UserId":31,"CharaId":13,"SummonData":"<base64>",
 "SummonDataVersion":3,"MatchingLevel":10,"Region":1,"RegionFlag":1,"NatType":2}
```

Four earlier attempts echoed the whole 28-field create request back; the client
parsed it and did nothing. The entry is a **projection of the decoded blob**, not
an echo of the request — the real server base64-decodes the sign and reads the
fields out with the same SOSSignMan struct the game uses. `CharaId` and
`MatchingLevel` therefore have to agree with the blob's own copies, and position
and area are absent because the game reads those from the blob directly. Which
is also why the blob must pass through byte-for-byte.

### SummonData blob layout (224 bytes, little-endian)

Established by diffing our own captured sign against a real one for a different
player — only thirteen byte-runs differ, which pins the variable fields exactly.

| offset | type | field |
|---|---|---|
| `0x00` | 4 × u32 | 1,000,000 each |
| `0x10` | 16 B | `0xff` filler |
| `0x20` | 4 × u32 | equipment ids 230000/231000/232000/233000 |
| `0x40` | 16 B | character name, null-padded |
| `0x50` | u32 | per-session nonce (differs per player) |
| `0x54` | f32 | `2.0` |
| `0x58` | u32 | `0x118` |
| `0x5c` | 3 × f32 | world position X, Y, Z |
| `0x68` | f32 | facing angle |
| `0x6c` | u32 | `AreaRegionId` (241010; matches the JSON field) |
| `0x70` | u32 | **`MatchingLevel`** — mirrored into the JSON entry |
| `0x7d` | bytes | **PSN online id (NPID)**, null-padded |
| `0xd8` | u64 | **`CharaId`** — mirrored into the JSON entry |

The NPID is the only routing information in the whole sign, and it must be a
name registered on our shadNet instance, or `CmdRequestSignalingInfos` returns
`NotFound` and signaling never starts.

Specifically it is the profile's **`shadnet_npid`** field, *not* the profile
display name. `np_handler.cpp:84` passes `u->shadnet_npid` to `ConnectUser`,
which is what `SetNpId` writes into `m_np_ids[user_id]`; `GetOnlineId` returns
that handle, and that is what the game copies into the blob at `0x7d`. The
display name (`u->user_name`) is only ever logged. So the one identity that has
to line up is `shadnet_npid` == the name registered with `shadnet-accounts.sh`.

### Identity

Signs are stored by NPID. Self-exclusion compares `(UserId, CharaId)`, because a
`GetList` request carries no blob and that pair is the only identity present in
both messages.


## Reference

Log filter syntax (`src/common/logging/log.cpp:285`): space-separated
`Class:level` pairs, `*` sets the default. Levels are spdlog names
(`trace debug info warning error critical off`). Class names are in
`src/common/logging/classes.h`.

Paths on Linux — a portable `user/` directory in the **current working
directory** takes priority, otherwise `$XDG_DATA_HOME/shadPS4` or
`~/.local/share/shadPS4`:

- config: `<userdir>/config.json` → `["Log"]["filter"]`
- log: `<userdir>/log/shad_log.txt`
- host overrides: `<userdir>/host_overrides.json`

Bloodborne serials: `CUSA00900` (US), `CUSA03173`, `CUSA00208`, `CUSA00207`,
`CUSA01363`, `CUSA03023`, `CUSA00299`, `CUSA03014`.

## Prior art for the session server

Build clean-room, from captures you take yourself. Reference these (community
reverse-engineering, safe to read) rather than any unpublished Hunter's Dream
source:

- **[DS3OS](https://github.com/TLeonardUK/ds3os)** — open-source DS2/DS3 server
  with co-op matchmaking, invasions, messages, bloodstains, and published
  protobuf definitions. Bloodborne (2015) sits between DS2 and DS3 (2016), so
  its session protocol is very likely a close cousin. **This is the single most
  useful reference.**
- **[DS3 netcode RE writeup](https://timleonard.uk/2022/05/29/reverse-engineering-dark-souls-3-networking)**
- **[Waygate](https://github.com/vswarte/waygate-server)** — same idea for Elden Ring.
- **[RPCN](https://wiki.rpcs3.net/index.php?title=Help%3ANetplay)** — the PSN
  replacement shadPS4's networking is modeled on.