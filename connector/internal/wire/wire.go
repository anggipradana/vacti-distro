// Package wire is the stream protocol shared by the connector, the relay and
// the scan-side tunnel.
//
// Transport: one WebSocket per peer, carried as a net.Conn and multiplexed with
// yamux. Every yamux stream starts with an Open header and gets one Reply; for
// "tcp" the stream then carries raw bytes, for "udp"/"dns" it carries
// length-prefixed datagrams (see WriteDatagram / ReadDatagram).
//
// Stream types:
//
//	tcp    dial Dst (ip:port) inside the customer network and pipe bytes
//	udp    send/receive datagrams to Dst (ip:port)
//	dns    forward DNS packets to the connector host's own resolver
//	ping   one ICMP echo to Dst (ip); Reply carries the RTT
//	grant  (relay -> connector only) install a signed session grant
//	revoke (relay -> connector only) drop a session grant
package wire

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"time"
)

const (
	TypeTCP    = "tcp"
	TypeUDP    = "udp"
	TypeDNS    = "dns"
	TypePing   = "ping"
	TypeGrant  = "grant"
	TypeRevoke = "revoke"
)

// Error codes carried in Reply.Err. Kept short and generic on purpose.
const (
	ErrScope       = "scope"       // destination outside the session grant
	ErrNoSession   = "no_session"  // unknown / expired session
	ErrRefused     = "refused"     // TCP RST from the destination
	ErrUnreachable = "unreachable" // no route / host down
	ErrTimeout     = "timeout"
	ErrBadRequest  = "bad_request"
	ErrUnavailable = "unavailable" // connector offline (relay side)
)

// MaxHeader bounds a header so a peer cannot make us allocate arbitrarily.
const MaxHeader = 16 * 1024

// MaxDatagram is the largest UDP/DNS payload carried on a datagram stream.
const MaxDatagram = 65535

// Open is the first message on every stream.
type Open struct {
	T   string `json:"t"`
	Sid string `json:"sid,omitempty"`
	Dst string `json:"dst,omitempty"`
	// grant only: the signed grant bytes and their ed25519 signature (base64).
	Grant string `json:"grant,omitempty"`
	Sig   string `json:"sig,omitempty"`
}

// Reply answers an Open.
type Reply struct {
	OK    bool   `json:"ok"`
	Err   string `json:"err,omitempty"`
	RttUs int64  `json:"rtt_us,omitempty"`
}

func writeFrame(w io.Writer, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	if len(b) > MaxHeader {
		return errors.New("header too large")
	}
	var hdr [2]byte
	binary.BigEndian.PutUint16(hdr[:], uint16(len(b)))
	if _, err := w.Write(append(hdr[:], b...)); err != nil {
		return err
	}
	return nil
}

func readFrame(r io.Reader, v any) error {
	var hdr [2]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return err
	}
	n := int(binary.BigEndian.Uint16(hdr[:]))
	if n == 0 || n > MaxHeader {
		return fmt.Errorf("bad header length %d", n)
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return err
	}
	return json.Unmarshal(buf, v)
}

func WriteOpen(w io.Writer, o Open) error   { return writeFrame(w, o) }
func ReadOpen(r io.Reader) (Open, error)    { var o Open; err := readFrame(r, &o); return o, err }
func WriteReply(w io.Writer, rp Reply) error { return writeFrame(w, rp) }
func ReadReply(r io.Reader) (Reply, error)  { var rp Reply; err := readFrame(r, &rp); return rp, err }

// WriteDatagram writes one length-prefixed datagram.
func WriteDatagram(w io.Writer, p []byte) error {
	if len(p) > MaxDatagram {
		return errors.New("datagram too large")
	}
	buf := make([]byte, 2+len(p))
	binary.BigEndian.PutUint16(buf, uint16(len(p)))
	copy(buf[2:], p)
	_, err := w.Write(buf)
	return err
}

// ReadDatagram reads one length-prefixed datagram into a fresh slice.
func ReadDatagram(r io.Reader) ([]byte, error) {
	var hdr [2]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return nil, err
	}
	buf := make([]byte, binary.BigEndian.Uint16(hdr[:]))
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	return buf, nil
}

// Deadline is a small helper for header exchanges.
func Deadline(d time.Duration) time.Time { return time.Now().Add(d) }
