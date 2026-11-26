// relay pairs scan-side tunnels with connectors. It runs in Oryx's own
// cluster; both sides dial out to it, so neither the customer network nor the
// scan device needs an inbound port.
//
//	GET /v1/connect  connector (Bearer connector token, verified by the API)
//	GET /v1/session  scan tunnel (Bearer session token, HS256, minted by the API)
//	GET /healthz
//
// The relay never interprets traffic. For each scan stream it re-stamps the
// session id from the verified token (a scan device cannot borrow another
// session) and forwards the stream to the connector, which enforces the
// API-signed grant on its own.
package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/hashicorp/yamux"

	"github.com/anggipradana/vacti-distro/connector/internal/transport"
	"github.com/anggipradana/vacti-distro/connector/internal/wire"
)

var version = "dev"

type config struct {
	listen        string
	apiURL        string
	sharedSecret  string
	sessionSecret []byte
}

type connectorSession struct {
	id    string
	token string
	sess  *yamux.Session
}

type relay struct {
	cfg  config
	http *http.Client
	mu   sync.Mutex
	conn map[string]*connectorSession
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	cfg := config{
		listen:        envOr("RELAY_LISTEN", ":8080"),
		apiURL:        strings.TrimRight(os.Getenv("RELAY_API_URL"), "/"),
		sharedSecret:  secretFromEnv("RELAY_SHARED_SECRET"),
		sessionSecret: []byte(secretFromEnv("RELAY_SESSION_SECRET")),
	}
	if cfg.apiURL == "" || len(cfg.sharedSecret) < 32 || len(cfg.sessionSecret) < 32 {
		log.Fatal("RELAY_API_URL, RELAY_SHARED_SECRET (>=32) and RELAY_SESSION_SECRET (>=32) are required")
	}
	r := &relay{cfg: cfg, http: &http.Client{Timeout: 10 * time.Second}, conn: map[string]*connectorSession{}}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(w, "ok") })
	mux.HandleFunc("GET /v1/connect", r.handleConnect)
	mux.HandleFunc("GET /v1/session", r.handleSession)
	srv := &http.Server{Addr: cfg.listen, Handler: mux, ReadHeaderTimeout: 10 * time.Second}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(sctx)
	}()
	log.Printf("relay %s listening on %s", version, cfg.listen)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func envOr(k, d string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return d
}

// secretFromEnv reads a secret from env var k, or, when that is empty, from the
// file named by k_FILE (the Docker/Compose secrets convention). Keeping the
// value in a root-owned file instead of the process environment means it never
// appears in `docker inspect` or a compose env file.
func secretFromEnv(k string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	if p := strings.TrimSpace(os.Getenv(k + "_FILE")); p != "" {
		if b, err := os.ReadFile(p); err == nil {
			return strings.TrimSpace(string(b))
		}
	}
	return ""
}

func bearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if len(h) > 7 && strings.EqualFold(h[:7], "bearer ") {
		return strings.TrimSpace(h[7:])
	}
	return ""
}

func clientIP(r *http.Request) string {
	if v := r.Header.Get("CF-Connecting-IP"); v != "" {
		return v
	}
	if v := r.Header.Get("X-Forwarded-For"); v != "" {
		return strings.TrimSpace(strings.Split(v, ",")[0])
	}
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	return host
}

// ── API callbacks ───────────────────────────────────────────────────────────

func (r *relay) api(path string, body any, out any) (int, error) {
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, r.cfg.apiURL+path, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Relay-Secret", r.cfg.sharedSecret)
	resp, err := r.http.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if out != nil && resp.StatusCode == http.StatusOK {
		// Accept both the enveloped {"data": {...}} shape and a flat body. The
		// vacti API answers verify-connector FLAT ({"connectorId": ...}); reading
		// only env.Data failed to decode it, so every connector got a 503 at
		// /v1/connect and could never come online.
		raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		if err != nil {
			return resp.StatusCode, err
		}
		var env struct {
			Data json.RawMessage `json:"data"`
		}
		if err := json.Unmarshal(raw, &env); err != nil {
			return resp.StatusCode, err
		}
		body := raw
		if len(env.Data) > 0 && string(env.Data) != "null" {
			body = env.Data
		}
		if err := json.Unmarshal(body, out); err != nil {
			return resp.StatusCode, err
		}
	}
	return resp.StatusCode, nil
}

type verifyResult struct {
	ConnectorID string `json:"connectorId"`
}

func (r *relay) verifyConnector(token string) (string, int, error) {
	var out verifyResult
	status, err := r.api("/api/internal/relay/verify-connector", map[string]string{"token": token}, &out)
	if err != nil {
		return "", 0, err
	}
	if status != http.StatusOK || out.ConnectorID == "" {
		return "", status, fmt.Errorf("rejected (%d)", status)
	}
	return out.ConnectorID, status, nil
}

// sessionEvent tells the API about a scan session's lifecycle so the grant
// ledger records when the tunnel was actually used and ended. It returns false
// only when the API EXPLICITLY refuses the session (grant revoked or expired,
// or the engagement it serves has ended); a transport error or an older API
// without this route never tears a live tunnel down.
func (r *relay) sessionEvent(c *sessionClaims, event string) bool {
	status, err := r.api("/api/internal/relay/session-status", map[string]string{
		"sid": c.Sid, "connectorId": c.Conn, "scanId": c.Scan, "event": event,
	}, nil)
	if err != nil {
		log.Printf("session %s %s report failed: %v", c.Sid, event, err)
		return true
	}
	switch status {
	case http.StatusUnauthorized, http.StatusForbidden, http.StatusGone:
		return false
	}
	return true
}

func (r *relay) reportStatus(id, status, ip, ver string) {
	// "online"/"ip" are the field names the API reads; "status"/"remoteIp" are
	// kept for older APIs. Without "online": false a disconnect never registered
	// and a dead connector stayed "online" in the dashboard.
	if _, err := r.api("/api/internal/relay/connector-status", map[string]any{
		"connectorId": id, "status": status, "online": status == "online",
		"remoteIp": ip, "ip": ip, "version": ver,
	}, nil); err != nil {
		log.Printf("status report for %s failed: %v", id, err)
	}
}

// ── connector side ──────────────────────────────────────────────────────────

func (r *relay) handleConnect(w http.ResponseWriter, req *http.Request) {
	token := bearer(req)
	if token == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	id, status, err := r.verifyConnector(token)
	if err != nil {
		if status == http.StatusUnauthorized || status == http.StatusForbidden || status == http.StatusNotFound {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
		} else {
			http.Error(w, "unavailable", http.StatusServiceUnavailable)
		}
		return
	}
	nc, err := transport.Accept(w, req)
	if err != nil {
		return
	}
	// The relay opens streams toward the connector, so it is the yamux client.
	sess, err := yamux.Client(nc, transport.YamuxConfig())
	if err != nil {
		nc.Close()
		return
	}
	cs := &connectorSession{id: id, token: token, sess: sess}
	r.mu.Lock()
	if old := r.conn[id]; old != nil {
		// Single active instance: the newest connection wins.
		old.sess.Close()
	}
	r.conn[id] = cs
	r.mu.Unlock()

	ip := clientIP(req)
	ver := strings.TrimPrefix(req.Header.Get("User-Agent"), "connector/")
	log.Printf("connector %s connected from %s", id, ip)
	go r.reportStatus(id, "online", ip, ver)

	// Re-verify periodically so a revoke in the dashboard drops the tunnel.
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()
	closed := sess.CloseChan()
loop:
	for {
		select {
		case <-closed:
			break loop
		case <-ticker.C:
			if _, status, err := r.verifyConnector(token); err != nil &&
				(status == http.StatusUnauthorized || status == http.StatusForbidden || status == http.StatusNotFound) {
				log.Printf("connector %s revoked; closing", id)
				sess.Close()
				break loop
			}
			// Presence heartbeat: the API's "online" must not be a stale
			// connect-time artifact. Refresh lastSeenAt while the session is
			// alive; a dead connector stops refreshing and the API treats it
			// as offline after its staleness window.
			go r.reportStatus(id, "online", ip, ver)
		}
	}
	r.mu.Lock()
	current := r.conn[id] == cs
	if current {
		delete(r.conn, id)
	}
	r.mu.Unlock()
	if current {
		log.Printf("connector %s disconnected", id)
		go r.reportStatus(id, "offline", ip, ver)
	}
}

// ── scan side ───────────────────────────────────────────────────────────────

type sessionClaims struct {
	Sid   string `json:"sid"`
	Conn  string `json:"conn"`
	Scan  string `json:"scan"`
	Exp   int64  `json:"exp"`
	Grant string `json:"grant"`
	Sig   string `json:"gsig"`
}

// verifySession checks an HS256 JWT minted by the API.
func (r *relay) verifySession(tok string) (*sessionClaims, error) {
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		return nil, errors.New("malformed")
	}
	hdr, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, errors.New("malformed")
	}
	var h struct {
		Alg string `json:"alg"`
	}
	if json.Unmarshal(hdr, &h) != nil || h.Alg != "HS256" {
		return nil, errors.New("bad alg")
	}
	mac := hmac.New(sha256.New, r.cfg.sessionSecret)
	mac.Write([]byte(parts[0] + "." + parts[1]))
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || subtle.ConstantTimeCompare(sig, mac.Sum(nil)) != 1 {
		return nil, errors.New("bad signature")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, errors.New("malformed")
	}
	var c sessionClaims
	if err := json.Unmarshal(payload, &c); err != nil {
		return nil, errors.New("malformed")
	}
	if c.Sid == "" || c.Conn == "" || c.Grant == "" || c.Sig == "" {
		return nil, errors.New("incomplete")
	}
	if time.Now().Unix() >= c.Exp {
		return nil, errors.New("expired")
	}
	return &c, nil
}

func (r *relay) connector(id string) *connectorSession {
	r.mu.Lock()
	defer r.mu.Unlock()
	cs := r.conn[id]
	if cs == nil || cs.sess.IsClosed() {
		return nil
	}
	return cs
}

// control sends one grant/revoke stream to the connector and waits for its reply.
func control(cs *connectorSession, o wire.Open) error {
	s, err := cs.sess.OpenStream()
	if err != nil {
		return err
	}
	defer s.Close()
	_ = s.SetDeadline(wire.Deadline(15 * time.Second))
	if err := wire.WriteOpen(s, o); err != nil {
		return err
	}
	rp, err := wire.ReadReply(s)
	if err != nil {
		return err
	}
	if !rp.OK {
		return fmt.Errorf("connector refused: %s", rp.Err)
	}
	return nil
}

func (r *relay) handleSession(w http.ResponseWriter, req *http.Request) {
	claims, err := r.verifySession(bearer(req))
	if err != nil {
		// Log the reason (never the token) so a broken session is diagnosable
		// from the relay side; the tunnel only sees a refused SOCKS connect.
		log.Printf("session refused from %s: %v", clientIP(req), err)
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	cs := r.connector(claims.Conn)
	if cs == nil {
		log.Printf("session %s (scan %s) refused: connector %s is offline", claims.Sid, claims.Scan, claims.Conn)
		http.Error(w, "connector offline", http.StatusServiceUnavailable)
		return
	}
	// Ask the API whether this grant is still live before installing it: an
	// operator revoke or an engagement that already ended must not reopen.
	if !r.sessionEvent(claims, "attached") {
		log.Printf("session %s (scan %s) refused by the API", claims.Sid, claims.Scan)
		http.Error(w, "session revoked", http.StatusForbidden)
		return
	}
	if err := control(cs, wire.Open{T: wire.TypeGrant, Grant: claims.Grant, Sig: claims.Sig}); err != nil {
		log.Printf("grant for scan %s rejected by connector %s: %v", claims.Scan, claims.Conn, err)
		http.Error(w, "connector rejected session", http.StatusBadGateway)
		return
	}
	nc, err := transport.Accept(w, req)
	if err != nil {
		return
	}
	// The scan side opens streams, so the relay is the yamux server here.
	ws, err := yamux.Server(nc, transport.YamuxConfig())
	if err != nil {
		nc.Close()
		return
	}
	log.Printf("session %s (scan %s) attached to connector %s", claims.Sid, claims.Scan, claims.Conn)
	defer func() {
		ws.Close()
		if cs := r.connector(claims.Conn); cs != nil {
			_ = control(cs, wire.Open{T: wire.TypeRevoke, Sid: claims.Sid})
		}
		go r.sessionEvent(claims, "closed")
		log.Printf("session %s closed", claims.Sid)
	}()

	expiry := time.Until(time.Unix(claims.Exp, 0))
	timer := time.AfterFunc(expiry, func() { ws.Close() })
	defer timer.Stop()

	// Re-check the session with the API every minute, like the connector side
	// does: cancelling the engagement or revoking the connector in the
	// dashboard drops the tunnel within one cycle instead of at grant expiry.
	go func() {
		t := time.NewTicker(60 * time.Second)
		defer t.Stop()
		closed := ws.CloseChan()
		for {
			select {
			case <-closed:
				return
			case <-t.C:
				if !r.sessionEvent(claims, "alive") {
					log.Printf("session %s revoked by the API; closing", claims.Sid)
					ws.Close()
					return
				}
			}
		}
	}()

	for {
		s, err := ws.AcceptStream()
		if err != nil {
			return
		}
		go r.forward(s, claims)
	}
}

func (r *relay) forward(s *yamux.Stream, claims *sessionClaims) {
	_ = s.SetReadDeadline(wire.Deadline(15 * time.Second))
	o, err := wire.ReadOpen(s)
	_ = s.SetReadDeadline(time.Time{})
	if err != nil {
		s.Close()
		return
	}
	switch o.T {
	case wire.TypeTCP, wire.TypeUDP, wire.TypeDNS, wire.TypePing:
	default:
		_ = wire.WriteReply(s, wire.Reply{Err: wire.ErrBadRequest})
		s.Close()
		return
	}
	o.Sid = claims.Sid // never trust the scan side's session id
	o.Grant, o.Sig = "", ""
	cs := r.connector(claims.Conn)
	if cs == nil {
		_ = wire.WriteReply(s, wire.Reply{Err: wire.ErrUnavailable})
		s.Close()
		return
	}
	up, err := cs.sess.OpenStream()
	if err != nil {
		_ = wire.WriteReply(s, wire.Reply{Err: wire.ErrUnavailable})
		s.Close()
		return
	}
	if err := wire.WriteOpen(up, o); err != nil {
		up.Close()
		s.Close()
		return
	}
	// The connector's Reply and everything after it flow back untouched.
	transport.Pipe(s, up)
}
