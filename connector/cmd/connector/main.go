// connector is the only component that runs inside a customer network.
//
// It is deliberately small: it enrols once, keeps one outbound WebSocket to the
// relay, and for each stream opens a TCP/UDP socket, a DNS query or an ICMP
// echo toward an address the session's signed grant allows. It holds no
// assessment logic, prompts, tools or model credentials, listens on no port,
// and never accepts traffic from the network it sits in.
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/rand/v2"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/hashicorp/yamux"
	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"

	"github.com/anggipradana/vacti-distro/connector/internal/grant"
	"github.com/anggipradana/vacti-distro/connector/internal/transport"
	"github.com/anggipradana/vacti-distro/connector/internal/wire"
)

// version is set at build time (-ldflags "-X main.version=...").
var version = "dev"

type state struct {
	ConnectorID string `json:"connectorId"`
	Token       string `json:"token"`
	RelayURL    string `json:"relayUrl"`
	GrantKey    string `json:"grantKey"` // base64 raw ed25519 public key
	Install     string `json:"install,omitempty"` // sha256 of the consumed install id
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	log.SetPrefix("connector: ")

	stateDir := envOr("VACTI_CONNECTOR_STATE", "/var/lib/connector")
	st, err := loadOrEnroll(stateDir)
	if err != nil {
		log.Fatalf("enrollment failed: %v", err)
	}
	pub, err := base64.StdEncoding.DecodeString(st.GrantKey)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		log.Fatalf("stored state is invalid; re-enrol with a new install id")
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	c := &conn{id: st.ConnectorID, pub: ed25519.PublicKey(pub), grants: map[string]*grant.Verified{}}
	go c.reapGrants(ctx)

	backoff := time.Second
	for ctx.Err() == nil {
		started := time.Now()
		status, err := c.serve(ctx, st)
		if ctx.Err() != nil {
			break
		}
		if status == http.StatusUnauthorized || status == http.StatusForbidden {
			// Revoked or replaced: stop instead of hammering the relay.
			log.Printf("access revoked; re-enrol from the dashboard")
			os.Exit(3)
		}
		if time.Since(started) > time.Minute {
			backoff = time.Second
		}
		log.Printf("disconnected (%v); retrying in %s", errOrNil(err), backoff)
		select {
		case <-ctx.Done():
		case <-time.After(backoff + time.Duration(rand.Int64N(int64(backoff/2)+1))):
		}
		if backoff < time.Minute {
			backoff *= 2
		}
	}
	log.Printf("stopped")
}

func errOrNil(err error) any {
	if err == nil {
		return "closed"
	}
	return err
}

func envOr(k, d string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return d
}

// ── enrollment ──────────────────────────────────────────────────────────────

var installIDRe = regexp.MustCompile(`^[A-Za-z0-9_-]{16,128}$`)

func digest(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

// probeWritable writes and removes a scratch file in dir, failing fast when the
// process cannot persist state there. Called before bootstrap so a bad mount
// never burns the single-use install id (see loadOrEnroll).
func probeWritable(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp := filepath.Join(dir, ".write-probe")
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	closeErr := f.Close()
	os.Remove(tmp)
	if closeErr != nil {
		return closeErr
	}
	return nil
}

func loadOrEnroll(dir string) (*state, error) {
	path := filepath.Join(dir, "state.json")
	install := strings.TrimSpace(os.Getenv("VACTI_INSTALL_ID"))
	_ = os.Unsetenv("VACTI_INSTALL_ID")

	var existing *state
	if b, err := os.ReadFile(path); err == nil {
		var s state
		if json.Unmarshal(b, &s) == nil && s.ConnectorID != "" && s.Token != "" {
			existing = &s
		}
	}
	// Restart with the install id that produced the stored state: reuse it.
	// A different install id is a deliberate reinstall and enrols again.
	if existing != nil && (install == "" || existing.Install == digest(install)) {
		return existing, nil
	}
	if install == "" {
		return nil, errors.New("no stored identity and VACTI_INSTALL_ID is not set")
	}
	if !installIDRe.MatchString(install) {
		return nil, errors.New("VACTI_INSTALL_ID has an invalid format")
	}
	api := strings.TrimRight(envOr("VACTI_API_URL", ""), "/")
	if !strings.HasPrefix(api, "https://") && !strings.HasPrefix(api, "http://") {
		return nil, errors.New("VACTI_API_URL must be an http(s) URL")
	}
	// Probe the identity dir BEFORE bootstrap. Bootstrap consumes the
	// single-use install id server-side; if persistence then fails (a fresh
	// named volume initialised root-owned against this nonroot image, for
	// example), every retry re-presents an already-consumed id and the
	// connector is dead on arrival with no recovery but a fresh ticket.
	if err := probeWritable(dir); err != nil {
		return nil, fmt.Errorf("cannot persist identity here: %w (mount a writable volume at %s)", err, dir)
	}
	req, _ := http.NewRequest(http.MethodPost, api+"/api/connector/enroll/"+install, nil)
	req.Header.Set("User-Agent", "connector/"+version)
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("bootstrap request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("bootstrap rejected (HTTP %d): the install id is unknown, used or expired", resp.StatusCode)
	}
	var s state
	if err := json.NewDecoder(io.LimitReader(resp.Body, 64*1024)).Decode(&s); err != nil {
		return nil, errors.New("bootstrap response was not understood")
	}
	if s.ConnectorID == "" || s.Token == "" || s.GrantKey == "" ||
		!(strings.HasPrefix(s.RelayURL, "wss://") || strings.HasPrefix(s.RelayURL, "ws://")) {
		return nil, errors.New("bootstrap response is incomplete")
	}
	s.Install = digest(install)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("cannot create %s: %w", dir, err)
	}
	b, _ := json.MarshalIndent(s, "", "  ")
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return nil, fmt.Errorf("cannot persist identity: %w (mount a writable volume at %s)", err, dir)
	}
	if err := os.Rename(tmp, path); err != nil {
		return nil, err
	}
	log.Printf("enrolled")
	return &s, nil
}

// ── relay session ───────────────────────────────────────────────────────────

type conn struct {
	id     string
	pub    ed25519.PublicKey
	mu     sync.Mutex
	grants map[string]*grant.Verified
}

func (c *conn) serve(ctx context.Context, st *state) (int, error) {
	h := http.Header{}
	h.Set("Authorization", "Bearer "+st.Token)
	h.Set("User-Agent", "connector/"+version)
	nc, status, err := transport.Dial(ctx, strings.TrimRight(st.RelayURL, "/")+"/v1/connect", h)
	if err != nil {
		return status, err
	}
	sess, err := yamux.Server(nc, transport.YamuxConfig())
	if err != nil {
		nc.Close()
		return 0, err
	}
	defer sess.Close()
	log.Printf("connected")
	go func() {
		<-ctx.Done()
		sess.Close()
	}()
	for {
		s, err := sess.AcceptStream()
		if err != nil {
			c.clearGrants()
			return 0, err
		}
		go c.handle(s)
	}
}

func (c *conn) reapGrants(ctx context.Context) {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			c.mu.Lock()
			for sid, g := range c.grants {
				if g.Expired(now) {
					delete(c.grants, sid)
				}
			}
			c.mu.Unlock()
		}
	}
}

func (c *conn) clearGrants() {
	c.mu.Lock()
	c.grants = map[string]*grant.Verified{}
	c.mu.Unlock()
}

func (c *conn) lookup(sid string) *grant.Verified {
	c.mu.Lock()
	defer c.mu.Unlock()
	g := c.grants[sid]
	if g == nil || g.Expired(time.Now()) {
		return nil
	}
	return g
}

func reply(s net.Conn, ok bool, code string) {
	_ = s.SetWriteDeadline(wire.Deadline(10 * time.Second))
	_ = wire.WriteReply(s, wire.Reply{OK: ok, Err: code})
	_ = s.SetWriteDeadline(time.Time{})
}

func (c *conn) handle(s *yamux.Stream) {
	_ = s.SetReadDeadline(wire.Deadline(15 * time.Second))
	o, err := wire.ReadOpen(s)
	_ = s.SetReadDeadline(time.Time{})
	if err != nil {
		s.Close()
		return
	}
	switch o.T {
	case wire.TypeGrant:
		g, err := grant.Verify(c.pub, o.Grant, o.Sig, c.id, time.Now())
		if err != nil {
			reply(s, false, wire.ErrBadRequest)
			s.Close()
			return
		}
		c.mu.Lock()
		c.grants[g.Sid] = g
		c.mu.Unlock()
		log.Printf("session opened (%d ranges)", len(g.CIDRs))
		reply(s, true, "")
		s.Close()
		return
	case wire.TypeRevoke:
		c.mu.Lock()
		_, had := c.grants[o.Sid]
		delete(c.grants, o.Sid)
		c.mu.Unlock()
		if had {
			log.Printf("session closed")
		}
		reply(s, true, "")
		s.Close()
		return
	}

	g := c.lookup(o.Sid)
	if g == nil {
		reply(s, false, wire.ErrNoSession)
		s.Close()
		return
	}
	switch o.T {
	case wire.TypeTCP:
		c.tcp(s, g, o.Dst)
	case wire.TypeUDP:
		c.udp(s, g, o.Dst)
	case wire.TypeDNS:
		c.dns(s)
	case wire.TypePing:
		c.ping(s, g, o.Dst)
	default:
		reply(s, false, wire.ErrBadRequest)
		s.Close()
	}
}

func allowedAddrPort(g *grant.Verified, dst string) (netip.AddrPort, bool) {
	ap, err := netip.ParseAddrPort(dst)
	if err != nil || ap.Port() == 0 {
		return netip.AddrPort{}, false
	}
	return ap, g.Scope.Allows(ap.Addr())
}

func dialErr(err error) string {
	var ne net.Error
	switch {
	case errors.As(err, &ne) && ne.Timeout():
		return wire.ErrTimeout
	case errors.Is(err, syscall.ECONNREFUSED):
		return wire.ErrRefused
	default:
		return wire.ErrUnreachable
	}
}

func (c *conn) tcp(s *yamux.Stream, g *grant.Verified, dst string) {
	ap, ok := allowedAddrPort(g, dst)
	if !ok {
		reply(s, false, wire.ErrScope)
		s.Close()
		return
	}
	d := net.Dialer{Timeout: 6 * time.Second}
	tc, err := d.Dial("tcp", ap.String())
	if err != nil {
		reply(s, false, dialErr(err))
		s.Close()
		return
	}
	reply(s, true, "")
	transport.Pipe(s, tc)
}

// datagramLoop relays length-prefixed datagrams between the stream and a
// connected UDP socket until either side is idle for `idle` or closes.
func datagramLoop(s *yamux.Stream, uc *net.UDPConn, idle time.Duration) {
	defer s.Close()
	defer uc.Close()
	go func() {
		buf := make([]byte, wire.MaxDatagram)
		for {
			_ = uc.SetReadDeadline(time.Now().Add(idle))
			n, err := uc.Read(buf)
			if err != nil {
				s.Close()
				return
			}
			if wire.WriteDatagram(s, buf[:n]) != nil {
				return
			}
		}
	}()
	for {
		_ = s.SetReadDeadline(time.Now().Add(idle))
		p, err := wire.ReadDatagram(s)
		if err != nil {
			return
		}
		if _, err := uc.Write(p); err != nil {
			return
		}
	}
}

func (c *conn) udp(s *yamux.Stream, g *grant.Verified, dst string) {
	ap, ok := allowedAddrPort(g, dst)
	if !ok {
		reply(s, false, wire.ErrScope)
		s.Close()
		return
	}
	uc, err := net.DialUDP("udp", nil, net.UDPAddrFromAddrPort(ap))
	if err != nil {
		reply(s, false, dialErr(err))
		s.Close()
		return
	}
	reply(s, true, "")
	datagramLoop(s, uc, 60*time.Second)
}

// resolver returns the host's own DNS server (the one the connector itself
// uses), so internal names resolve exactly as they do for machines there.
func resolver() string {
	if v := strings.TrimSpace(os.Getenv("VACTI_CONNECTOR_DNS")); v != "" {
		if ap, err := netip.ParseAddrPort(v); err == nil {
			return ap.String()
		}
		if a, err := netip.ParseAddr(v); err == nil {
			return netip.AddrPortFrom(a, 53).String()
		}
	}
	b, err := os.ReadFile("/etc/resolv.conf")
	if err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			f := strings.Fields(line)
			if len(f) >= 2 && f[0] == "nameserver" {
				if a, err := netip.ParseAddr(f[1]); err == nil {
					return netip.AddrPortFrom(a, 53).String()
				}
			}
		}
	}
	return "127.0.0.53:53"
}

func (c *conn) dns(s *yamux.Stream) {
	ap, err := netip.ParseAddrPort(resolver())
	if err != nil {
		reply(s, false, wire.ErrUnreachable)
		s.Close()
		return
	}
	uc, err := net.DialUDP("udp", nil, net.UDPAddrFromAddrPort(ap))
	if err != nil {
		reply(s, false, wire.ErrUnreachable)
		s.Close()
		return
	}
	reply(s, true, "")
	datagramLoop(s, uc, 30*time.Second)
}

func (c *conn) ping(s *yamux.Stream, g *grant.Verified, dst string) {
	defer s.Close()
	addr, err := netip.ParseAddr(dst)
	if err != nil || !addr.Is4() || !g.Scope.Allows(addr) {
		reply(s, false, wire.ErrScope)
		return
	}
	// Unprivileged ICMP ("ping socket"); Docker enables ping_group_range by default.
	pc, err := icmp.ListenPacket("udp4", "0.0.0.0")
	if err != nil {
		reply(s, false, wire.ErrUnavailable)
		return
	}
	defer pc.Close()
	msg := icmp.Message{Type: ipv4.ICMPTypeEcho, Body: &icmp.Echo{ID: rand.IntN(0xffff), Seq: 1, Data: []byte("connector")}}
	b, _ := msg.Marshal(nil)
	start := time.Now()
	if _, err := pc.WriteTo(b, &net.UDPAddr{IP: net.IP(addr.AsSlice())}); err != nil {
		reply(s, false, wire.ErrUnreachable)
		return
	}
	_ = pc.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 1500)
	for {
		n, _, err := pc.ReadFrom(buf)
		if err != nil {
			reply(s, false, wire.ErrTimeout)
			return
		}
		m, err := icmp.ParseMessage(1, buf[:n])
		if err == nil && m.Type == ipv4.ICMPTypeEchoReply {
			_ = s.SetWriteDeadline(wire.Deadline(10 * time.Second))
			_ = wire.WriteReply(s, wire.Reply{OK: true, RttUs: time.Since(start).Microseconds()})
			return
		}
	}
}
