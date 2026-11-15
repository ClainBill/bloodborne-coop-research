#!/usr/bin/env python3
"""
Logging HTTP proxy for Bloodborne's session server traffic.

The game reaches its session server over plain HTTP (port 18671, plus the
ss.info bootstrap on 20443), and shadPS4's host_overrides.json can redirect any
host the game builds a URL for -- including the dynamic ones it learns from
ss.info. Pointing both at 127.0.0.1 puts this proxy in the middle, where it
records full request and response bodies and forwards everything untouched.

That is strictly more than tcpdump gives you (decoded bodies, correlated
request/response pairs, no root) and it is also the skeleton of the Phase 3
server: start by forwarding everything, then replace endpoints one at a time
with your own implementations.

Stdlib only -- nothing to install on the Deck.

Usage:
    ./bb-proxy.py                       # listen 18671+20443, forward upstream
    ./bb-proxy.py --upstream HOST       # default thehuntersdream.com
    ./bb-proxy.py --ports 18671 20443
    ./bb-proxy.py --outdir ./capture    # where transcripts land
"""

import argparse
import datetime
import http.client
import http.server
import os
import socketserver
import sys
import threading

LOCK = threading.Lock()
ARGS = None
LOGFILE = None
SEQ = 0

# Hop-by-hop headers must not be forwarded (RFC 7230 6.1). Passing these through
# is what causes mysterious hangs and double-encoded bodies in naive proxies.
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
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


def describe_body(data):
    """Render a body readably. FromSoft payloads are frequently binary, so fall
    back to a hex+ascii dump rather than mangling it through a text decode."""
    if not data:
        return "    (empty)"
    try:
        text = data.decode("utf-8")
        if text.isprintable() or "\n" in text:
            return "\n".join("    " + ln for ln in text.splitlines())
    except UnicodeDecodeError:
        pass

    out = []
    for off in range(0, min(len(data), 2048), 16):
        chunk = data[off : off + 16]
        hexpart = " ".join(f"{b:02x}" for b in chunk).ljust(47)
        asciipart = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        out.append(f"    {off:04x}  {hexpart}  |{asciipart}|")
    if len(data) > 2048:
        out.append(f"    ... ({len(data) - 2048} more bytes)")
    return "\n".join(out)


def save_raw(seq, kind, data):
    if not data or not ARGS.raw:
        return
    path = os.path.join(ARGS.outdir, f"{seq:05d}-{kind}.bin")
    with open(path, "wb") as fh:
        fh.write(data)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    # Quieten the default per-request stderr logging; we do our own.
    def log_message(self, fmt, *a):
        pass

    def proxy(self):
        global SEQ
        with LOCK:
            SEQ += 1
            seq = SEQ

        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""

        port = self.server.server_address[1]
        emit(
            f"\n{'=' * 78}\n"
            f"[{stamp()}] #{seq} --> {self.command} {self.path}  (port {port})"
        )
        for k, v in self.headers.items():
            emit(f"    {k}: {v}")
        if body:
            emit("  request body:")
            emit(describe_body(body))
        save_raw(seq, "request", body)

        # Forward upstream, preserving method, path and body. Host is rewritten
        # to the real server -- shadPS4 rewrote it to 127.0.0.1 on the way in.
        fwd = {
            k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP
        }
        # Normally the upstream port matches the one we accepted on, because the
        # host override preserves it. --upstream-port overrides that, for when
        # your own replacement server listens somewhere else.
        up_port = ARGS.upstream_port or port
        fwd["Host"] = f"{ARGS.upstream}:{up_port}"

        try:
            conn = http.client.HTTPConnection(
                ARGS.upstream, up_port, timeout=ARGS.timeout
            )
            conn.request(self.command, self.path, body=body, headers=fwd)
            resp = conn.getresponse()
            resp_body = resp.read()
        except Exception as exc:
            emit(f"[{stamp()}] #{seq} !!! upstream error: {exc}")
            # 502 rather than a dropped connection, so the game gets a definite
            # answer instead of hanging on a read.
            self.send_response(502)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        emit(f"[{stamp()}] #{seq} <-- {resp.status} {resp.reason}  ({len(resp_body)} bytes)")
        for k, v in resp.getheaders():
            emit(f"    {k}: {v}")
        if resp_body:
            emit("  response body:")
            emit(describe_body(resp_body))
        save_raw(seq, "response", resp_body)

        self.send_response(resp.status, resp.reason)
        for k, v in resp.getheaders():
            if k.lower() not in HOP_BY_HOP and k.lower() != "content-length":
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(resp_body)))
        self.end_headers()
        self.wfile.write(resp_body)
        conn.close()

    # The game uses several verbs; route them all through the same path.
    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = do_PATCH = do_OPTIONS = proxy


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    global ARGS, LOGFILE
    ap = argparse.ArgumentParser()
    ap.add_argument("--upstream", default="thehuntersdream.com")
    ap.add_argument("--ports", nargs="+", type=int, default=[18671, 20443])
    ap.add_argument(
        "--upstream-port",
        type=int,
        default=0,
        help="forward to this port instead of the one we listened on",
    )
    ap.add_argument("--outdir", default=".")
    ap.add_argument("--timeout", type=float, default=15.0)
    ap.add_argument(
        "--raw",
        action="store_true",
        help="also dump each body to its own .bin (useful for replay in Phase 3)",
    )
    ARGS = ap.parse_args()

    os.makedirs(ARGS.outdir, exist_ok=True)
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    logpath = os.path.join(ARGS.outdir, f"http-transcript-{ts}.log")
    LOGFILE = open(logpath, "w")

    emit(f"transcript: {logpath}")
    emit(f"upstream  : {ARGS.upstream}")

    servers = []
    for port in ARGS.ports:
        try:
            srv = Server(("127.0.0.1", port), Handler)
        except OSError as exc:
            emit(f"!! cannot bind 127.0.0.1:{port}: {exc}")
            emit("   (already running? another proxy instance?)")
            return 1
        servers.append(srv)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        emit(f"listening : 127.0.0.1:{port} -> {ARGS.upstream}:{port}")

    emit("\nReady. Put this in host_overrides.json, then launch the game:\n")
    emit('  {')
    emit('    "ss4.scej-network.jp": "http://127.0.0.1",')
    emit(f'    "{ARGS.upstream}": "http://127.0.0.1"')
    emit('  }')
    emit("\n(target port omitted on purpose -- shadPS4 then preserves the")
    emit(" original port, so 18671 and 20443 both route here.)")
    emit("\nCtrl-C to stop.\n")

    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        emit(f"\nstopped. transcript: {logpath}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
