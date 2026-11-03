#!/usr/bin/env python3
"""mock-cp-server.py - a SCOPED test fixture that imitates ONLY the vacti control
plane endpoints the appliance enrollment flow touches. It is NOT, and must never
be used as, a control-plane replacement: it mints nothing real, authenticates
nothing real, and serves a clearly-labelled STUB engine package, not the real
vacti-engine. Its entire reason to exist is to let the e2e harness assert the
appliance's client-side short-code + enroll + apt-pull plumbing hermetically,
without a live CP and without the real engine .deb.

Implemented surface (mirrors distro/enroll/common/pairing-exchange.sh and
distro/golden-image/docker-entrypoint.sh contracts, confirmed from the repo):

  POST /api/pentest/enroll/exchange   {"code":"K7X9R8W2"}
        200 {"token": "<full-uuid>"}  valid, unexpired, unconsumed  (consumes it)
        404                           code not found
        410                           code expired OR already consumed
        429                           per-IP lockout after N failed attempts
     Codes are normalised exactly as the client + CP do:
        re.sub(r'[\\s-]+', '', code).upper()

  POST /api/pentest/enroll            Bearer <full-token>  {"engine_id": "..."}
        200 {"producer_token","verifier_token","gatekeeper_token"}
        401                           unknown/!issued token

  Private apt repo (served only when --serve-apt):
     GET  /apt/Release, /apt/Packages[.gz], /apt/<pool>/<stub>.deb
     HTTP Basic: login MUST be 'vacti', password MUST be a token THIS server
     issued (an exchanged enroll token or a producer token). Every apt GET is
     recorded with the token used, so the harness can assert the engine .deb was
     pulled with the EXCHANGED token.

  Admin (loopback + X-Mock-Admin only; never part of the imitated CP surface):
     POST /__admin/mint     {"code","ttl_seconds","token"?}
     POST /__admin/expire   {"code"}
     POST /__admin/consume  {"code"}
     GET  /__admin/state
     POST /__admin/reset

No pairing code, enroll token or admin token VALUE is ever logged.
"""
import argparse
import gzip
import hashlib
import io
import os
import re
import sys
import tarfile
import threading
import time
import uuid

try:
    from flask import Flask, request, jsonify, Response
except Exception as exc:  # pragma: no cover - surfaced at runtime, not py_compile
    sys.stderr.write(
        "mock-cp-server: Flask is required (pip install -r test/e2e/requirements.txt): %s\n" % exc
    )
    raise

# ---------------------------------------------------------------------------
# State (in-process; the harness inspects it via /__admin/state).
# ---------------------------------------------------------------------------
_LOCK = threading.RLock()
STATE = {
    "codes": {},          # normalised_code -> {token, expires_at, consumed, minted_at}
    "issued_tokens": {},  # full_token -> {from_code}
    "exchange_fail_by_ip": {},  # ip -> count of failed exchange attempts
    "requests": [],       # append-only audit log of imitated-CP requests
}
LOCKOUT_THRESHOLD = 10    # 10 failures allowed; the 11th attempt is locked out (429)
ADMIN_TOKEN = ""
SERVE_APT = False
_STUB_DEB = {"path": None, "name": None, "size": 0, "sha256": ""}

CODE_RE = re.compile(r"[\s-]+")


def normalize_code(raw):
    return CODE_RE.sub("", raw or "").upper()


def _record(kind, **fields):
    with _LOCK:
        STATE["requests"].append(dict(kind=kind, ts=time.time(), **fields))


app = Flask(__name__)


# ---------------------------------------------------------------------------
# Imitated CP: short-code exchange
# ---------------------------------------------------------------------------
@app.post("/api/pentest/enroll/exchange")
def exchange():
    ip = request.remote_addr or "?"
    body = request.get_json(silent=True) or {}
    code = normalize_code(body.get("code", ""))
    with _LOCK:
        fails = STATE["exchange_fail_by_ip"].get(ip, 0)
        if fails >= LOCKOUT_THRESHOLD:
            _record("exchange", result=429, ip=ip, present=bool(code))
            return jsonify(error="rate_limited"), 429
        entry = STATE["codes"].get(code)
        now = time.time()
        if entry is None:
            STATE["exchange_fail_by_ip"][ip] = fails + 1
            _record("exchange", result=404, ip=ip, present=bool(code))
            return jsonify(error="not_found"), 404
        if entry["consumed"] or now >= entry["expires_at"]:
            STATE["exchange_fail_by_ip"][ip] = fails + 1
            _record("exchange", result=410, ip=ip,
                    reason=("consumed" if entry["consumed"] else "expired"))
            return jsonify(error="gone"), 410
        # success: consume, issue token, reset this IP's failure counter.
        entry["consumed"] = True
        token = entry["token"]
        STATE["issued_tokens"][token] = {"from_code": code}
        STATE["exchange_fail_by_ip"][ip] = 0
        _record("exchange", result=200, ip=ip)
    return jsonify(token=token), 200


# ---------------------------------------------------------------------------
# Imitated CP: enroll handshake
# ---------------------------------------------------------------------------
@app.post("/api/pentest/enroll")
def enroll():
    auth = request.headers.get("Authorization", "")
    token = auth[7:].strip() if auth.lower().startswith("bearer ") else ""
    body = request.get_json(silent=True) or {}
    engine_id = body.get("engine_id", "")
    with _LOCK:
        known = token in STATE["issued_tokens"]
    if not token or not known:
        _record("enroll", result=401, engine_id=engine_id)
        return jsonify(error="unauthorized"), 401
    _record("enroll", result=200, engine_id=engine_id,
            token_from_code=STATE["issued_tokens"][token].get("from_code"))
    # engineSharedSecret mirrors the real control plane (libs/api pentest-routes enroll
    # response): the X-Engine-Auth value the first-boot writer must persist as
    # VACTI_ENGINE_SHARED_SECRET so off-tailnet engines clear the edge Basic gate on their
    # first heartbeat. A real CP returns "" when its own env var is unset (feature off).
    return jsonify(
        producer_token="prod-" + uuid.uuid4().hex,
        verifier_token="ver-" + uuid.uuid4().hex,
        gatekeeper_token="gk-" + uuid.uuid4().hex,
        engineSharedSecret=os.environ.get("MOCK_ENGINE_SHARED_SECRET", ""),
    ), 200


# ---------------------------------------------------------------------------
# Imitated private apt repo (stub engine package only)
# ---------------------------------------------------------------------------
def _apt_auth_token():
    """Return the Basic-auth password IF login is 'vacti' and the password is a
    token this server issued; else None. Mirrors the appliance's auth.conf
    (machine .../apt login vacti password <enroll-or-producer-token>)."""
    a = request.authorization
    if not a or a.username != "vacti" or not a.password:
        return None
    with _LOCK:
        if a.password in STATE["issued_tokens"]:
            return a.password
    # also accept a producer token the harness pre-seeded (full-token scenarios)
    if a.password in PRODUCER_TOKENS:
        return a.password
    return None


PRODUCER_TOKENS = set()  # seeded via --producer-token for scenario 4


def _require_apt():
    if not SERVE_APT:
        return Response("apt serving disabled (start with --serve-apt)\n", 501)
    tok = _apt_auth_token()
    if tok is None:
        resp = Response("auth required\n", 401)
        resp.headers["WWW-Authenticate"] = 'Basic realm="vacti-apt"'
        return resp
    return tok  # a truthy str


@app.get("/apt/Release")
def apt_release():
    tok = _require_apt()
    if isinstance(tok, Response):
        return tok
    _record("apt", path="/apt/Release", token_issued=True,
            token_from_code=_token_origin(tok))
    pkgs = _packages_text().encode()
    body = (
        "Origin: vacti-mock\nLabel: vacti-mock\nSuite: ./\n"
        "Architectures: all amd64 arm64\nComponents: \n"
        "MD5Sum:\n SHA256:\n %s %d Packages\n"
        % (hashlib.sha256(pkgs).hexdigest(), len(pkgs))
    )
    return Response(body, mimetype="text/plain")


def _packages_text():
    name = _STUB_DEB["name"] or "vacti-engine_0.0.0-test_all.deb"
    return (
        "Package: vacti-engine\nVersion: 0.0.0-test\nArchitecture: all\n"
        "Maintainer: vacti-e2e-fixture <noreply@invalid>\n"
        "Filename: pool/%s\nSize: %d\nSHA256: %s\n"
        "Description: STUB engine package - e2e fixture, NOT the real vacti-engine\n\n"
        % (name, _STUB_DEB["size"], _STUB_DEB["sha256"])
    )


@app.get("/apt/Packages")
def apt_packages():
    tok = _require_apt()
    if isinstance(tok, Response):
        return tok
    _record("apt", path="/apt/Packages", token_from_code=_token_origin(tok))
    return Response(_packages_text(), mimetype="text/plain")


@app.get("/apt/Packages.gz")
def apt_packages_gz():
    tok = _require_apt()
    if isinstance(tok, Response):
        return tok
    _record("apt", path="/apt/Packages.gz", token_from_code=_token_origin(tok))
    return Response(gzip.compress(_packages_text().encode()),
                    mimetype="application/gzip")


@app.get("/apt/pool/<path:deb>")
def apt_deb(deb):
    tok = _require_apt()
    if isinstance(tok, Response):
        return tok
    _record("apt", path="/apt/pool/%s" % deb, token_from_code=_token_origin(tok),
            is_deb=True)
    if not _STUB_DEB["path"] or not os.path.exists(_STUB_DEB["path"]):
        return Response("stub deb unavailable\n", 503)
    with open(_STUB_DEB["path"], "rb") as fh:
        return Response(fh.read(), mimetype="application/vnd.debian.binary-package")


def _token_origin(tok):
    with _LOCK:
        if tok in STATE["issued_tokens"]:
            return STATE["issued_tokens"][tok].get("from_code")
    return "producer" if tok in PRODUCER_TOKENS else None


# ---------------------------------------------------------------------------
# Admin surface (loopback + token only)
# ---------------------------------------------------------------------------
def _admin_ok():
    ip = request.remote_addr or ""
    if ip not in ("127.0.0.1", "::1", "::ffff:127.0.0.1"):
        return False
    return bool(ADMIN_TOKEN) and request.headers.get("X-Mock-Admin", "") == ADMIN_TOKEN


@app.post("/__admin/mint")
def admin_mint():
    if not _admin_ok():
        return jsonify(error="forbidden"), 403
    body = request.get_json(silent=True) or {}
    code = normalize_code(body.get("code", ""))
    if not code:
        return jsonify(error="code required"), 400
    ttl = float(body.get("ttl_seconds", 600))
    token = body.get("token") or uuid.uuid4().hex
    with _LOCK:
        STATE["codes"][code] = {
            "token": token, "expires_at": time.time() + ttl,
            "consumed": False, "minted_at": time.time(),
        }
    return jsonify(ok=True, code_len=len(code)), 200


@app.post("/__admin/issue-token")
def admin_issue_token():
    # Pre-register a FULL enrollment token WITHOUT an exchange, so the backward-
    # compat scenario (VACTI_ENROLL_TOKEN=<uuid>, no short code) can authenticate
    # the apt pull and the enroll POST exactly as the pre-short-code path did.
    if not _admin_ok():
        return jsonify(error="forbidden"), 403
    token = (request.get_json(silent=True) or {}).get("token", "")
    if not token:
        return jsonify(error="token required"), 400
    with _LOCK:
        STATE["issued_tokens"][token] = {"from_code": None}
    return jsonify(ok=True), 200


@app.post("/__admin/expire")
def admin_expire():
    if not _admin_ok():
        return jsonify(error="forbidden"), 403
    code = normalize_code((request.get_json(silent=True) or {}).get("code", ""))
    with _LOCK:
        if code in STATE["codes"]:
            STATE["codes"][code]["expires_at"] = time.time() - 1
            return jsonify(ok=True), 200
    return jsonify(error="unknown code"), 404


@app.post("/__admin/consume")
def admin_consume():
    if not _admin_ok():
        return jsonify(error="forbidden"), 403
    code = normalize_code((request.get_json(silent=True) or {}).get("code", ""))
    with _LOCK:
        if code in STATE["codes"]:
            STATE["codes"][code]["consumed"] = True
            return jsonify(ok=True), 200
    return jsonify(error="unknown code"), 404


@app.get("/__admin/state")
def admin_state():
    if not _admin_ok():
        return jsonify(error="forbidden"), 403
    with _LOCK:
        # redact token VALUES; expose only non-sensitive shape for assertions.
        codes = {
            c: {"consumed": v["consumed"],
                "expired": time.time() >= v["expires_at"],
                "has_token": bool(v["token"])}
            for c, v in STATE["codes"].items()
        }
        return jsonify(
            codes=codes,
            issued_token_count=len(STATE["issued_tokens"]),
            exchange_fail_by_ip=dict(STATE["exchange_fail_by_ip"]),
            requests=STATE["requests"],
        ), 200


@app.post("/__admin/reset")
def admin_reset():
    if not _admin_ok():
        return jsonify(error="forbidden"), 403
    with _LOCK:
        STATE["codes"].clear()
        STATE["issued_tokens"].clear()
        STATE["exchange_fail_by_ip"].clear()
        STATE["requests"].clear()
    return jsonify(ok=True), 200


@app.get("/healthz")
def healthz():
    return jsonify(ok=True, serve_apt=SERVE_APT), 200


# ---------------------------------------------------------------------------
# Stub .deb builder (pure-python ar+tar; no dpkg-deb dependency).
# The package ships ONLY fixture markers so the appliance's apt pull + install
# path completes: /usr/lib/vacti-engine/dist/runner/cli.js (the marker the
# entrypoint checks) and a trivial systemd unit. It is NOT the real engine.
# ---------------------------------------------------------------------------
def _tar_gz_bytes(members):
    """members: list of (name, mode, data_bytes). Returns gzipped tar bytes."""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w") as tar:
        for name, mode, data in members:
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = mode
            info.mtime = 0
            tar.addfile(info, io.BytesIO(data))
    return gzip.compress(raw.getvalue())


def _ar_bytes(members):
    """Minimal GNU ar archive. members: list of (name, data_bytes)."""
    out = io.BytesIO()
    out.write(b"!<arch>\n")
    for name, data in members:
        hdr = "%-16s%-12d%-6d%-6d%-8s%-10d`\n" % (name, 0, 0, 0, "100644", len(data))
        out.write(hdr.encode())
        out.write(data)
        if len(data) % 2:
            out.write(b"\n")
    return out.getvalue()


def build_stub_deb(dest_dir):
    cli_js = (
        "#!/usr/bin/env node\n"
        "// STUB vacti-engine runner (e2e fixture, NOT the real engine).\n"
        "console.log('vacti-engine STUB runner up (e2e fixture)');\n"
        "setInterval(function(){}, 1 << 30);\n"
    ).encode()
    unit = (
        "[Unit]\nDescription=vacti engine (e2e STUB fixture)\n"
        "[Service]\nType=simple\n"
        "ExecStart=/usr/bin/env node /usr/lib/vacti-engine/dist/runner/cli.js\n"
        "Restart=no\n[Install]\nWantedBy=multi-user.target\n"
    ).encode()
    data_tar = _tar_gz_bytes([
        ("./usr/lib/vacti-engine/dist/runner/cli.js", 0o755, cli_js),
        ("./etc/systemd/system/vacti-engine.service", 0o644, unit),
    ])
    control = (
        "Package: vacti-engine\nVersion: 0.0.0-test\nArchitecture: all\n"
        "Maintainer: vacti-e2e-fixture <noreply@invalid>\nSection: misc\n"
        "Priority: optional\n"
        "Description: STUB engine package - e2e fixture, NOT the real vacti-engine\n"
    ).encode()
    postinst = (
        "#!/bin/sh\nset -e\n"
        "if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then\n"
        "  systemctl daemon-reload || true\n"
        "  systemctl enable --now vacti-engine.service || true\n"
        "fi\n"
    ).encode()
    control_tar = _tar_gz_bytes([
        ("./control", 0o644, control),
        ("./postinst", 0o755, postinst),
    ])
    deb = _ar_bytes([
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", control_tar),
        ("data.tar.gz", data_tar),
    ])
    os.makedirs(dest_dir, exist_ok=True)
    name = "vacti-engine_0.0.0-test_all.deb"
    path = os.path.join(dest_dir, name)
    with open(path, "wb") as fh:
        fh.write(deb)
    _STUB_DEB.update(path=path, name=name, size=len(deb),
                     sha256=hashlib.sha256(deb).hexdigest())
    return path


def main(argv=None):
    global ADMIN_TOKEN, SERVE_APT
    p = argparse.ArgumentParser(description="vacti e2e mock CP fixture (NOT a real CP)")
    p.add_argument("--host", default=os.environ.get("MOCK_CP_HOST", "127.0.0.1"))
    p.add_argument("--port", type=int, default=int(os.environ.get("MOCK_CP_PORT", "8080")))
    p.add_argument("--admin-token", default=os.environ.get("MOCK_ADMIN_TOKEN", ""))
    p.add_argument("--serve-apt", action="store_true",
                   default=os.environ.get("MOCK_SERVE_APT", "") == "1")
    p.add_argument("--deb-dir", default=os.environ.get("MOCK_DEB_DIR", "/tmp/vacti-e2e-deb"))
    p.add_argument("--producer-token", default=os.environ.get("MOCK_PRODUCER_TOKEN", ""),
                   help="seed a full producer token (scenario 4 backward-compat)")
    args = p.parse_args(argv)

    ADMIN_TOKEN = args.admin_token
    SERVE_APT = args.serve_apt
    if not ADMIN_TOKEN:
        sys.stderr.write("mock-cp-server: refusing to start without --admin-token\n")
        return 2
    if args.producer_token:
        PRODUCER_TOKENS.add(args.producer_token)
    if SERVE_APT:
        build_stub_deb(args.deb_dir)
        sys.stderr.write("mock-cp-server: serving STUB apt repo (fixture deb only)\n")
    sys.stderr.write("mock-cp-server: imitated CP on %s:%d (test fixture only)\n"
                     % (args.host, args.port))
    app.run(host=args.host, port=args.port, threaded=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
