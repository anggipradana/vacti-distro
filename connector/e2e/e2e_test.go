// End-to-end proof of the intranet connector chain, entirely on loopback:
//
//	stub API ── bootstrap/verify ──► relay ──wss/yamux──► connector ──► echo server
//	                                  ▲
//	tunnel (SOCKS5) ──wss/yamux───────┘
//
// A test client dials the echo server THROUGH the tunnel's SOCKS5 proxy and
// asserts the payload round-trips — i.e. the grant signature, the wire
// protocol and the SOCKS5 encapsulation all agree across the three binaries.
// The echo server binds the host's first non-loopback IPv4 address because
// the connector's scope hard-denies loopback (by design), exactly as it will
// in a real customer network.
package e2e

import (
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/proxy"
)

const (
	sharedSecret  = "test-shared-secret-0123456789abcdef0123456789"
	sessionSecret = "test-session-secret-0123456789abcdef0123456789"
	relayListen   = "127.0.0.1:18090"
	tunnelListen  = "127.0.0.1:18091"
	echoPort      = "18092"
)

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func hs256(payload map[string]any) string {
	hdr := b64url([]byte(`{"alg":"HS256","typ":"JWT"}`))
	p, _ := json.Marshal(payload)
	body := b64url(p)
	mac := hmac.New(sha256.New, []byte(sessionSecret))
	mac.Write([]byte(hdr + "." + body))
	return hdr + "." + body + "." + b64url(mac.Sum(nil))
}

func hostIPv4(t *testing.T) string {
	t.Helper()
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		t.Skipf("no interfaces: %v", err)
	}
	for _, a := range addrs {
		if ipn, ok := a.(*net.IPNet); ok && ipn.IP.To4() != nil && !ipn.IP.IsLoopback() {
			return ipn.IP.String()
		}
	}
	t.Skip("no non-loopback IPv4 address on this host")
	return ""
}

func build(t *testing.T, pkg, out string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), out)
	cmd := exec.Command("go", "build", "-o", path, pkg)
	cmd.Dir = ".."
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build %s: %v\n%s", pkg, err, b)
	}
	return path
}

func TestConnectorChainEndToEnd(t *testing.T) {
	target := hostIPv4(t)

	// ── echo server on the host's LAN address (scope denies loopback) ──
	ln, err := net.Listen("tcp", net.JoinHostPort(target, echoPort))
	if err != nil {
		t.Skipf("cannot bind %s:%s: %v", target, echoPort, err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				_, _ = io.Copy(c, c)
			}(c)
		}
	}()

	// ── stub API: bootstrap + relay callbacks ──
	var (
		grantPriv ed25519.PrivateKey
		grantPub  ed25519.PublicKey
	)
	online := make(chan struct{}, 4)
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/connector/enroll/{id}", func(w http.ResponseWriter, r *http.Request) {
		grantPub, grantPriv, _ = ed25519.GenerateKey(nil)
		w.Header().Set("Content-Type", "application/json")
		// Flat body: the connector's bootstrap decoder reads these at top level.
		_ = json.NewEncoder(w).Encode(map[string]any{
			"connectorId": "conn-1",
			"token":       "tok-1",
			"relayUrl":    "ws://" + relayListen,
			"grantKey":    base64.StdEncoding.EncodeToString(grantPub),
		})
	})
	mux.HandleFunc("POST /api/internal/relay/verify-connector", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Relay-Secret") != sharedSecret {
			http.Error(w, "bad secret", http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"success": true, "data": map[string]any{"connectorId": "conn-1"}})
	})
	mux.HandleFunc("POST /api/internal/relay/connector-status", func(w http.ResponseWriter, r *http.Request) {
		var body struct{ Status string `json:"status"` }
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Status == "online" {
			select {
			case online <- struct{}{}:
			default:
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"success": true})
	})
	api := httptest.NewServer(mux)
	defer api.Close()

	// ── the three binaries ──
	relayBin := build(t, "./cmd/relay", "relay")
	connBin := build(t, "./cmd/connector", "connector")
	tunBin := build(t, "./cmd/tunnel", "tunnel")

	stateDir := t.TempDir()
	start := func(bin string, env ...string) *exec.Cmd {
		cmd := exec.Command(bin)
		cmd.Env = append(os.Environ(), env...)
		cmd.Stdout = os.Stderr
		cmd.Stderr = os.Stderr
		if err := cmd.Start(); err != nil {
			t.Fatalf("start %s: %v", bin, err)
		}
		t.Cleanup(func() { _ = cmd.Process.Kill() })
		return cmd
	}
	start(relayBin,
		"RELAY_LISTEN="+relayListen,
		"RELAY_API_URL="+api.URL,
		"RELAY_SHARED_SECRET="+sharedSecret,
		"RELAY_SESSION_SECRET="+sessionSecret,
	)
	start(connBin,
		"VACTI_INSTALL_ID=e2e-install-id-0123456789",
		"VACTI_API_URL="+api.URL,
		"VACTI_CONNECTOR_STATE="+stateDir,
	)
	select {
	case <-online:
	case <-time.After(20 * time.Second):
		t.Fatal("connector never came online")
	}

	// ── mint a session grant exactly as the API route does ──
	grant, _ := json.Marshal(map[string]any{
		"v": 1, "sid": "sid-e2e", "conn": "conn-1", "scan": "scan-e2e",
		"cidrs": []string{target + "/32"},
		"exp":   time.Now().Add(time.Hour).Unix(),
	})
	sig := ed25519.Sign(grantPriv, grant)
	token := hs256(map[string]any{
		"sid": "sid-e2e", "conn": "conn-1", "scan": "scan-e2e",
		"exp":   time.Now().Add(time.Hour).Unix(),
		"grant": base64.StdEncoding.EncodeToString(grant),
		"gsig":  base64.StdEncoding.EncodeToString(sig),
	})
	start(tunBin,
		"VACTI_TUNNEL_LISTEN="+tunnelListen,
		"VACTI_TUNNEL_RELAY=ws://"+relayListen,
		"VACTI_TUNNEL_TOKEN="+token,
	)
	time.Sleep(500 * time.Millisecond)

	// ── dial the echo server THROUGH the tunnel's SOCKS5 proxy ──
	dialer, err := proxy.SOCKS5("tcp", tunnelListen, nil, proxy.Direct)
	if err != nil {
		t.Fatal(err)
	}
	conn, err := dialer.Dial("tcp", net.JoinHostPort(target, echoPort))
	if err != nil {
		t.Fatalf("dial through tunnel: %v", err)
	}
	defer conn.Close()
	want := "oryx-intranet-e2e-payload"
	if _, err := conn.Write([]byte(want)); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, len(want))
	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	if _, err := io.ReadFull(conn, got); err != nil {
		t.Fatalf("echo read: %v", err)
	}
	if string(got) != want {
		t.Fatalf("echo mismatch: got %q want %q", got, want)
	}
	fmt.Println("e2e: payload round-tripped through tunnel -> relay -> connector")
}

// TestScopeDeniesLoopbackEvenWhenGranted asserts the connector's own gate:
// a grant that tries to cover loopback is refused at parse time, so a
// mis-issued (or attacker-widened) session can never reach the host itself.
func TestScopeDeniesLoopbackEvenWhenGranted(t *testing.T) {
	cmd := exec.Command("go", "test", "./internal/scope/")
	cmd.Dir = ".."
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("scope tests failed:\n%s", out)
	}
	if !strings.Contains(string(out), "ok") {
		t.Fatalf("unexpected scope test output:\n%s", out)
	}
}

// TestUnwritableStateDirDoesNotBurnInstallTicket locks the ordering fix: a
// connector that cannot persist its identity must fail BEFORE bootstrap,
// because bootstrap consumes the single-use install id server-side. The live
// failure this prevents: a fresh named volume initialised root-owned against
// the nonroot image made persist fail AFTER bootstrap, so every retry
// re-presented a consumed id and the connector could never recover without a
// brand-new ticket.
//
// The unwritable dir is a path UNDER a regular file (MkdirAll fails with
// ENOTDIR), which behaves identically for root and non-root — so the test does
// not depend on who runs it.
func TestUnwritableStateDirDoesNotBurnInstallTicket(t *testing.T) {
	var bootstraps int32
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/connector/enroll/{id}", func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&bootstraps, 1)
		pub, _, _ := ed25519.GenerateKey(nil)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"connectorId": "conn-1",
			"token":       "tok-1",
			"relayUrl":    "ws://127.0.0.1:1",
			"grantKey":    base64.StdEncoding.EncodeToString(pub),
		})
	})
	api := httptest.NewServer(mux)
	defer api.Close()

	connBin := build(t, "./cmd/connector", "connector")
	install := "e2e-ticket-burn-0123456789"

	blocker := filepath.Join(t.TempDir(), "blocker")
	if err := os.WriteFile(blocker, []byte("x"), 0o644); err != nil {
		t.Fatalf("write blocker: %v", err)
	}
	badDir := filepath.Join(blocker, "state") // MkdirAll -> ENOTDIR

	run := func(stateDir string, wait time.Duration) *exec.Cmd {
		cmd := exec.Command(connBin)
		cmd.Env = append(os.Environ(),
			"VACTI_INSTALL_ID="+install,
			"VACTI_API_URL="+api.URL,
			"VACTI_CONNECTOR_STATE="+stateDir,
		)
		cmd.Stdout = os.Stderr
		cmd.Stderr = os.Stderr
		if err := cmd.Start(); err != nil {
			t.Fatalf("start connector: %v", err)
		}
		time.Sleep(wait)
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
		return cmd
	}

	// 1) Unwritable dir: the connector must retry WITHOUT ever calling
	//    bootstrap, so the ticket stays unconsumed.
	run(badDir, 3*time.Second)
	if n := atomic.LoadInt32(&bootstraps); n != 0 {
		t.Fatalf("unwritable state dir burned the ticket: bootstrap called %d time(s)", n)
	}

	// 2) The SAME install id must still enrol once the dir is writable —
	//    proof the ticket survived the failed attempt.
	goodDir := t.TempDir()
	run(goodDir, 3*time.Second)
	if n := atomic.LoadInt32(&bootstraps); n != 1 {
		t.Fatalf("expected exactly one bootstrap after fixing the dir, got %d", n)
	}
	if _, err := os.Stat(filepath.Join(goodDir, "state.json")); err != nil {
		t.Fatalf("identity not persisted after successful bootstrap: %v", err)
	}
	fmt.Println("e2e: unwritable state dir left the single-use ticket intact")
}
