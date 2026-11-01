#!/usr/bin/env node
/*
 * vacti-enroll-webui.js - the FAIL-CLOSED browser enrollment fallback for the
 * container image (TG 7212). When `docker run` is given NO enrollment token (no
 * -e VACTI_ENROLL_TOKEN / VACTI_TOKEN and no persisted engine.env), the
 * entrypoint runs THIS instead of die()ing: a tiny web UI on VACTI_WEBUI_PORT
 * (default 3100) where the user points a browser and pastes the control-plane URL
 * + the enrollment token ("license"). No `docker exec`, no shell.
 *
 * It drives the SAME single-use enroll handshake as the entrypoint / firstboot:
 * POST <url>/api/pentest/enroll  (Authorization: Bearer <token>, body {engine_id})
 * -> {producer,verifier,gatekeeper} -> writes STATE_ENV (0600) -> exits 0 so the
 * entrypoint continues and exec's the engine. A wrong/expired token re-renders the
 * form with an error and keeps serving; there is NO path to a shell. The token is
 * never logged and never written anywhere but the 0600 STATE_ENV the engine reads.
 *
 * Dependency-free: Node 22's global fetch + the built-in http module only.
 */
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = parseInt(process.env.VACTI_WEBUI_PORT || '3100', 10);
const HOST = process.env.VACTI_WEBUI_HOST || '0.0.0.0';
const STATE_ENV = process.env.STATE_ENV || '/var/lib/vacti-engine/engine.env';
const ENGINE_ID = process.env.ENGINE_ID || (process.env.HOSTNAME || 'engine');
const PREFILL_URL = process.env.VACTI_URL || '';

function log(msg) { process.stdout.write(`[vacti-webui] ${msg}\n`); }

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}

function page(opts) {
  const o = opts || {};
  const err = o.error
    ? `<p class="err" role="alert">${esc(o.error)}</p>`
    : '';
  const ok = o.ok
    ? `<p class="ok">${esc(o.ok)}</p>`
    : '';
  const form = o.done ? '' : `
    <form method="POST" action="/enroll" autocomplete="off">
      <label>Control-plane URL
        <input name="url" type="url" required placeholder="https://cp.example"
               value="${esc(o.url != null ? o.url : PREFILL_URL)}">
      </label>
      <label>Enrollment token (license)
        <input name="token" type="password" required
               placeholder="paste your single-use token (valid 3h)">
      </label>
      <button type="submit">Activate &amp; connect</button>
    </form>`;
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>vacti activation</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
         max-width: 34rem; margin: 3rem auto; padding: 0 1rem;
         background: #0b1220; color: #e7ecf5; }
  @media (prefers-color-scheme: light) { body { background: #f4f6fb; color: #16203a; } }
  h1 { font-size: 1.35rem; }
  p.sub { opacity: .8; font-size: .95rem; }
  label { display: block; margin: 1rem 0 .25rem; font-weight: 600; }
  input { width: 100%; padding: .6rem .7rem; border-radius: .5rem;
          border: 1px solid #39465f; background: transparent; color: inherit;
          font-size: 1rem; box-sizing: border-box; }
  button { margin-top: 1.25rem; padding: .7rem 1.1rem; border: 0; border-radius: .5rem;
           background: #2f6df6; color: #fff; font-size: 1rem; cursor: pointer; }
  .err { color: #ff8a8a; font-weight: 600; }
  .ok { color: #7ee2a8; font-weight: 600; }
  footer { margin-top: 2rem; font-size: .8rem; opacity: .65; }
</style></head>
<body>
  <h1>Activate this vacti engine</h1>
  <p class="sub">Paste the control-plane URL and the single-use enrollment token
  (license) your operator gave you. The engine enrolls and connects itself. No
  login and no shell access is needed.</p>
  ${err}${ok}${form}
  <footer>The token is used once to enroll and is never stored in plain form.</footer>
</body></html>`;
}

function send(res, code, html) {
  res.writeHead(code, {
    'Content-Type': 'text/html; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'",
  });
  res.end(html);
}

function parseBody(req) {
  return new Promise((resolve) => {
    let data = '';
    let tooBig = false;
    req.on('data', (c) => {
      data += c;
      if (data.length > 64 * 1024) { tooBig = true; req.destroy(); }
    });
    req.on('end', () => {
      if (tooBig) return resolve({});
      const out = {};
      for (const pair of data.split('&')) {
        if (!pair) continue;
        const i = pair.indexOf('=');
        const k = decodeURIComponent((i < 0 ? pair : pair.slice(0, i)).replace(/\+/g, ' '));
        const v = i < 0 ? '' : decodeURIComponent(pair.slice(i + 1).replace(/\+/g, ' '));
        out[k] = v;
      }
      resolve(out);
    });
    req.on('error', () => resolve({}));
  });
}

function writeStateEnv(base, resp) {
  const producer = resp.producer_token || resp.producer || '';
  const verifier = resp.verifier_token || resp.verifier || '';
  const gatekeeper = resp.gatekeeper_token || resp.gatekeeper || '';
  if (!producer) throw new Error('enroll response carried no producer token');
  const lines = [`VACTI_URL=${base}`, `VACTI_TOKEN=${producer}`];
  if (verifier) lines.push(`VACTI_VERIFIER_TOKEN=${verifier}`);
  if (gatekeeper) lines.push(`VACTI_GATEKEEPER_TOKEN=${gatekeeper}`);
  fs.mkdirSync(path.dirname(STATE_ENV), { recursive: true });
  fs.writeFileSync(STATE_ENV, lines.join('\n') + '\n', { mode: 0o600 });
  fs.chmodSync(STATE_ENV, 0o600);
}

async function enroll(url, token) {
  const base = String(url).replace(/\/+$/, '');
  if (!/^https?:\/\//i.test(base)) throw new Error('URL must start with http:// or https://');
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 60000);
  let r;
  try {
    r = await fetch(`${base}/api/pentest/enroll`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ engine_id: ENGINE_ID }),
      signal: ctrl.signal,
    });
  } finally {
    clearTimeout(timer);
  }
  const text = await r.text();
  if (r.status !== 200) {
    const snippet = text ? ` Response: ${text.slice(0, 200)}` : '';
    throw new Error(`enroll failed (HTTP ${r.status}). The token may be expired or already used (single-use, 3h). Re-mint in the dashboard and retry.${snippet}`);
  }
  let json;
  try { json = JSON.parse(text); } catch { throw new Error('enroll succeeded but the response was not JSON'); }
  writeStateEnv(base, json);
  return base;
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === 'GET' && (req.url === '/' || req.url.startsWith('/?'))) {
      return send(res, 200, page({}));
    }
    if (req.method === 'POST' && req.url === '/enroll') {
      const body = await parseBody(req);
      const url = (body.url || '').trim();
      const token = (body.token || '').trim();
      if (!url || !token) {
        return send(res, 400, page({ url, error: 'Both the control-plane URL and the enrollment token are required.' }));
      }
      try {
        const base = await enroll(url, token);
        log(`enrolled engine_id=${ENGINE_ID} at ${base} (token not logged); engine.env written`);
        send(res, 200, page({ done: true, ok: 'Activated. The engine is connecting now. You can close this tab.' }));
        setTimeout(() => { server.close(); process.exit(0); }, 400);
        return;
      } catch (e) {
        log(`enroll attempt failed: ${e.message}`);
        return send(res, 400, page({ url, error: e.message }));
      }
    }
    send(res, 404, page({ error: 'Not found. Go to / to activate.' }));
  } catch (e) {
    send(res, 500, page({ error: 'Internal error. Please retry.' }));
  }
});

server.listen(PORT, HOST, () => {
  log(`VACTI_ENROLL_WEBUI=listening on http://${HOST}:${PORT} (open it and paste your license token)`);
});
