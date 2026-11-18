// tunnel is the SCAN-side half of an intranet connector session. It runs on
// the scan worker (never in the customer network) and exposes a localhost-
// only SOCKS5 proxy; every connection through it is carried as one yamux
// stream on the single WebSocket session to the relay:
//
//	tool (curl, python, nmap…) ──SOCKS5──► tunnel ──wss/yamux──► relay ──► connector ──► intranet host
//
// The scan's tools reach it through the usual proxy env vars (ALL_PROXY /
// HTTPS_PROXY) with NO_PROXY keeping the Oryx API and LLM gateway direct, so
// nothing of the engagement's own control plane rides the tunnel.
//
// It holds exactly one credential: the session JWT minted by the API for
// this engagement (env VACTI_TUNNEL_TOKEN). It has no prompts, tools or model
// keys. Remote DNS is resolved THROUGH the tunnel (the connector's own
// resolver), so internal names work exactly as they do inside the network.
package main

import (
	"context"
	"encoding/binary"
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

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	log.SetPrefix("tunnel: ")

	listen := envOr("VACTI_TUNNEL_LISTEN", "127.0.0.1:1080")
	relay := strings.TrimRight(envOr("VACTI_TUNNEL_RELAY", ""), "/")
	token := strings.TrimSpace(os.Getenv("VACTI_TUNNEL_TOKEN"))
	if relay == "" || token == "" {
		log.Fatal("VACTI_TUNNEL_RELAY and VACTI_TUNNEL_TOKEN are required")
	}
	// Localhost-only, always: the tunnel is a per-scan tool, not a service.
	host, port, err := net.SplitHostPort(listen)
	if err != nil || (host != "127.0.0.1" && host != "localhost" && host != "::1") {
		log.Fatalf("VACTI_TUNNEL_LISTEN must bind loopback (got %q)", listen)
	}
	_ = port

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	t := &tunnel{relay: relay, token: token}
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	log.Printf("socks5 proxy on %s", listen)
	go func() {
		<-ctx.Done()
		_ = ln.Close()
		t.close()
	}()
	for {
		c, err := ln.Accept()
		if err != nil {
			if ctx.Err() == nil {
				log.Printf("accept: %v", err)
			}
			return
		}
		go t.socks(c)
	}
}

func envOr(k, d string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return d
}

type tunnel struct {
	relay string
	token string

	mu   sync.Mutex
	sess *yamux.Session
}

func (t *tunnel) close() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.sess != nil {
		_ = t.sess.Close()
		t.sess = nil
	}
}

// session returns the live yamux session, dialing the relay on first use or
// after a drop. One WebSocket carries every stream of this engagement.
func (t *tunnel) session() (*yamux.Session, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.sess != nil && !t.sess.IsClosed() {
		return t.sess, nil
	}
	h := http.Header{}
	h.Set("Authorization", "Bearer "+t.token)
	h.Set("User-Agent", "tunnel/"+version)
	nc, status, err := transport.Dial(context.Background(), t.relay+"/v1/session", h)
	if err != nil {
		return nil, fmt.Errorf("relay dial failed (HTTP %d): %w", status, err)
	}
	sess, err := yamux.Client(nc, transport.YamuxConfig())
	if err != nil {
		nc.Close()
		return nil, err
	}
	t.sess = sess
	return sess, nil
}

// open asks the relay for one stream of the given type toward dst and waits
// for the connector's Reply (scope check happens there, against the grant).
func (t *tunnel) open(typ, dst string) (*yamux.Stream, error) {
	sess, err := t.session()
	if err != nil {
		return nil, err
	}
	s, err := sess.OpenStream()
	if err != nil {
		t.close()
		return nil, err
	}
	_ = s.SetDeadline(wire.Deadline(20 * time.Second))
	if err := wire.WriteOpen(s, wire.Open{T: typ, Dst: dst}); err != nil {
		s.Close()
		t.close()
		return nil, err
	}
	rp, err := wire.ReadReply(s)
	_ = s.SetDeadline(time.Time{})
	if err != nil {
		s.Close()
		t.close()
		return nil, err
	}
	if !rp.OK {
		s.Close()
		return nil, fmt.Errorf("connector refused: %s", rp.Err)
	}
	return s, nil
}

// ── SOCKS5 (RFC 1928, no auth — loopback only) ──────────────────────────────

func (t *tunnel) socks(c net.Conn) {
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(30 * time.Second))
	buf := make([]byte, 3)
	if _, err := io.ReadFull(c, buf); err != nil || buf[0] != 5 {
		return
	}
	nmeth := int(buf[2])
	methods := make([]byte, nmeth)
	if _, err := io.ReadFull(c, methods); err != nil {
		return
	}
	// No-auth only: the tunnel binds loopback and the session JWT already
	// authenticates the engagement; a SOCKS auth layer would add nothing.
	if _, err := c.Write([]byte{5, 0}); err != nil {
		return
	}
	hdr := make([]byte, 4)
	if _, err := io.ReadFull(c, hdr); err != nil || hdr[0] != 5 {
		return
	}
	cmd, atyp := hdr[1], hdr[3]
	dst, err := readAddr(c, atyp)
	if err != nil {
		socksFail(c, 1)
		return
	}
	_ = c.SetDeadline(time.Time{})

	switch cmd {
	case 1: // CONNECT
		t.socksConnect(c, dst)
	case 3: // UDP ASSOCIATE
		t.socksUDP(c)
	default:
		socksFail(c, 7)
	}
}

func socksFail(c net.Conn, code byte) {
	_, _ = c.Write([]byte{5, code, 0, 1, 0, 0, 0, 0, 0, 0})
}

func readAddr(r io.Reader, atyp byte) (string, error) {
	switch atyp {
	case 1: // IPv4
		b := make([]byte, 4)
		if _, err := io.ReadFull(r, b); err != nil {
			return "", err
		}
		p := make([]byte, 2)
		if _, err := io.ReadFull(r, p); err != nil {
			return "", err
		}
		return fmt.Sprintf("%d.%d.%d.%d:%d", b[0], b[1], b[2], b[3], binary.BigEndian.Uint16(p)), nil
	case 3: // domain — resolved REMOTELY through the tunnel's DNS, so internal
		// names answer exactly as they do inside the customer network.
		l := make([]byte, 1)
		if _, err := io.ReadFull(r, l); err != nil {
			return "", err
		}
		name := make([]byte, l[0])
		if _, err := io.ReadFull(r, name); err != nil {
			return "", err
		}
		p := make([]byte, 2)
		if _, err := io.ReadFull(r, p); err != nil {
			return "", err
		}
		return fmt.Sprintf("%s:%d", name, binary.BigEndian.Uint16(p)), nil
	case 4: // IPv6
		b := make([]byte, 16)
		if _, err := io.ReadFull(r, b); err != nil {
			return "", err
		}
		p := make([]byte, 2)
		if _, err := io.ReadFull(r, p); err != nil {
			return "", err
		}
		ip := net.IP(b)
		return fmt.Sprintf("[%s]:%d", ip.String(), binary.BigEndian.Uint16(p)), nil
	}
	return "", errors.New("bad atyp")
}

func (t *tunnel) socksConnect(c net.Conn, dst string) {
	// A domain target is resolved inside the customer network first (their
	// DNS, their split-horizon answers), then dialed by IP: the connector's
	// grant is CIDR-based by design.
	if host, port, err := net.SplitHostPort(dst); err == nil && net.ParseIP(host) == nil {
		ip, err := t.resolve(host)
		if err != nil {
			socksFail(c, 4) // host unreachable
			return
		}
		dst = net.JoinHostPort(ip, port)
	}
	s, err := t.open(wire.TypeTCP, dst)
	if err != nil {
		socksFail(c, 1)
		return
	}
	defer s.Close()
	if _, err := c.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0}); err != nil {
		return
	}
	transport.Pipe(c, s)
}

// resolve answers one A/AAAA question through the tunnel's DNS stream.
func (t *tunnel) resolve(name string) (string, error) {
	s, err := t.open(wire.TypeDNS, "")
	if err != nil {
		return "", err
	}
	defer s.Close()
	q := dnsQuestion(name)
	if err := wire.WriteDatagram(s, q); err != nil {
		return "", err
	}
	_ = s.SetReadDeadline(time.Now().Add(6 * time.Second))
	a, err := wire.ReadDatagram(s)
	if err != nil {
		return "", err
	}
	return dnsFirstAnswer(a)
}

// socksUDP implements UDP ASSOCIATE. SOCKS5 carries a destination per
// datagram, while the connector's UDP stream is connected to ONE destination
// (named in its Open header) — so keep one stream per destination and
// multiplex the client's datagrams across them. Domains are resolved through
// the tunnel's DNS first: grants are CIDR-based.
func (t *tunnel) socksUDP(c net.Conn) {
	uc, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		socksFail(c, 1)
		return
	}
	defer uc.Close()
	_, p, _ := net.SplitHostPort(uc.LocalAddr().String())
	var pp [2]byte
	binary.BigEndian.PutUint16(pp[:], uint16(mustAtoi(p)))
	if _, err := c.Write(append([]byte{5, 0, 0, 1, 127, 0, 0, 1}, pp[:]...)); err != nil {
		return
	}

	var (
		mu         sync.Mutex
		streams    = map[string]*yamux.Stream{}
		clientAddr *net.UDPAddr
	)
	sendBack := func(dst string, payload []byte) {
		mu.Lock()
		to := clientAddr
		mu.Unlock()
		if to == nil {
			return
		}
		if b := socksWrap(dst, payload); b != nil {
			_, _ = uc.WriteToUDP(b, to)
		}
	}
	openFor := func(dst string) (*yamux.Stream, error) {
		mu.Lock()
		if s, ok := streams[dst]; ok {
			mu.Unlock()
			return s, nil
		}
		mu.Unlock()
		s, err := t.open(wire.TypeUDP, dst)
		if err != nil {
			return nil, err
		}
		go func() {
			for {
				d, err := wire.ReadDatagram(s)
				if err != nil {
					mu.Lock()
					delete(streams, dst)
					mu.Unlock()
					s.Close()
					return
				}
				sendBack(dst, d)
			}
		}()
		mu.Lock()
		streams[dst] = s
		mu.Unlock()
		return s, nil
	}

	// The UDP association lives and dies with the TCP control connection.
	done := make(chan struct{})
	go func() {
		defer close(done)
		buf := make([]byte, 16)
		for {
			if _, err := c.Read(buf); err != nil {
				return
			}
		}
	}()
	go func() {
		<-done
		_ = uc.Close()
		mu.Lock()
		for _, s := range streams {
			_ = s.Close()
		}
		mu.Unlock()
	}()

	buf := make([]byte, wire.MaxDatagram)
	for {
		n, from, err := uc.ReadFromUDP(buf)
		if err != nil {
			return
		}
		mu.Lock()
		clientAddr = from
		mu.Unlock()
		dst, payload, ok := socksUnwrap(buf[:n])
		if !ok {
			continue
		}
		if host, port, err := net.SplitHostPort(dst); err == nil && net.ParseIP(host) == nil {
			ip, err := t.resolve(host)
			if err != nil {
				continue
			}
			dst = net.JoinHostPort(ip, port)
		}
		s, err := openFor(dst)
		if err != nil {
			continue
		}
		_ = wire.WriteDatagram(s, payload)
	}
}

func isTimeout(err error) bool {
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}

func mustAtoi(s string) int {
	var n int
	_, _ = fmt.Sscanf(s, "%d", &n)
	return n
}

// socksUnwrap strips the SOCKS5 UDP header (FRAG=0, ATYP, addr, port) and
// returns "host:port" plus payload.
func socksUnwrap(d []byte) (string, []byte, bool) {
	if len(d) < 4 || d[0] != 0 || d[1] != 0 {
		return "", nil, false
	}
	atyp := d[3]
	off := 4
	var host string
	switch atyp {
	case 1:
		if len(d) < off+4+2 {
			return "", nil, false
		}
		host = fmt.Sprintf("%d.%d.%d.%d", d[4], d[5], d[6], d[7])
		off += 4
	case 3:
		if len(d) < off+1 {
			return "", nil, false
		}
		l := int(d[4])
		if len(d) < off+1+l+2 {
			return "", nil, false
		}
		host = string(d[5 : 5+l])
		off += 1 + l
	case 4:
		if len(d) < off+16+2 {
			return "", nil, false
		}
		host = net.IP(d[4:20]).String()
		off += 16
	default:
		return "", nil, false
	}
	port := binary.BigEndian.Uint16(d[off : off+2])
	off += 2
	return fmt.Sprintf("%s:%d", host, port), d[off:], true
}

// socksWrap builds the SOCKS5 UDP header for an IPv4 destination.
func socksWrap(dst string, payload []byte) []byte {
	host, portStr, err := net.SplitHostPort(dst)
	ip := net.ParseIP(host)
	port := uint64(mustAtoi(portStr))
	if err != nil || ip == nil || ip.To4() == nil || port == 0 || port > 65535 {
		return nil
	}
	out := []byte{0, 0, 0, 1, ip.To4()[0], ip.To4()[1], ip.To4()[2], ip.To4()[3], byte(port >> 8), byte(port)}
	return append(out, payload...)
}

// ── minimal DNS (A then AAAA) over the tunnel's datagram stream ─────────────

func dnsQuestion(name string) []byte {
	q := []byte{0xab, 0xcd, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0}
	for _, label := range strings.Split(name, ".") {
		if label == "" {
			continue
		}
		q = append(q, byte(len(label)))
		q = append(q, label...)
	}
	q = append(q, 0, 0, 1, 0, 1) // QTYPE=A QCLASS=IN
	return q
}

func dnsFirstAnswer(a []byte) (string, error) {
	if len(a) < 12 {
		return "", errors.New("short dns reply")
	}
	ancount := int(binary.BigEndian.Uint16(a[6:8]))
	off := 12
	// skip question
	for off < len(a) && a[off] != 0 {
		off += int(a[off]) + 1
	}
	off += 5 // root + qtype + qclass
	for i := 0; i < ancount && off+12 <= len(a); i++ {
		// name (may be compressed)
		if a[off]&0xc0 == 0xc0 {
			off += 2
		} else {
			for off < len(a) && a[off] != 0 {
				off += int(a[off]) + 1
			}
			off++
		}
		if off+10 > len(a) {
			break
		}
		rtype := binary.BigEndian.Uint16(a[off : off+2])
		rdlen := int(binary.BigEndian.Uint16(a[off+8 : off+10]))
		rdata := off + 10
		if rtype == 1 && rdlen == 4 && rdata+4 <= len(a) {
			return fmt.Sprintf("%d.%d.%d.%d", a[rdata], a[rdata+1], a[rdata+2], a[rdata+3]), nil
		}
		off = rdata + rdlen
	}
	return "", errors.New("no A record")
}
