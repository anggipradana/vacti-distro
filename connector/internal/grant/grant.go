// Package grant verifies session grants signed by the Oryx API.
//
// A grant names one connector, one session id, the CIDRs that session may
// reach, and an expiry. The API signs the exact JSON bytes with ed25519; the
// connector pins the API's public key at enrollment, so neither the relay nor
// a scan device can widen a session's scope.
package grant

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"time"

	"github.com/anggipradana/vacti-distro/connector/internal/scope"
)

// Grant is the signed payload.
type Grant struct {
	V     int      `json:"v"`
	Sid   string   `json:"sid"`
	Conn  string   `json:"conn"`
	Scan  string   `json:"scan"`
	CIDRs []string `json:"cidrs"`
	Exp   int64    `json:"exp"` // unix seconds
}

// Verified is a grant whose signature, connector id, expiry and CIDRs checked out.
type Verified struct {
	Grant
	Scope scope.Set
}

// Expired reports whether the grant is past its expiry at t.
func (v *Verified) Expired(t time.Time) bool { return t.Unix() >= v.Exp }

// Verify checks a base64 grant + base64 signature against the pinned key.
func Verify(pub ed25519.PublicKey, grantB64, sigB64, connectorID string, now time.Time) (*Verified, error) {
	raw, err := base64.StdEncoding.DecodeString(grantB64)
	if err != nil {
		return nil, errors.New("grant: bad encoding")
	}
	sig, err := base64.StdEncoding.DecodeString(sigB64)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return nil, errors.New("grant: bad signature encoding")
	}
	if len(pub) != ed25519.PublicKeySize || !ed25519.Verify(pub, raw, sig) {
		return nil, errors.New("grant: signature invalid")
	}
	var g Grant
	if err := json.Unmarshal(raw, &g); err != nil {
		return nil, errors.New("grant: bad payload")
	}
	if g.V != 1 || g.Sid == "" {
		return nil, errors.New("grant: unsupported version")
	}
	if g.Conn != connectorID {
		return nil, errors.New("grant: issued for another connector")
	}
	if now.Unix() >= g.Exp {
		return nil, errors.New("grant: expired")
	}
	set, err := scope.Parse(g.CIDRs)
	if err != nil {
		return nil, err
	}
	return &Verified{Grant: g, Scope: set}, nil
}
