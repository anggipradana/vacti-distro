package grant

import (
	"crypto/ed25519"
	"encoding/base64"
	"net/netip"
	"testing"
	"time"
)

func mustAddr(t *testing.T, ip string) netip.Addr {
	t.Helper()
	a, err := netip.ParseAddr(ip)
	if err != nil {
		t.Fatal(err)
	}
	return a
}

// Cross-language acceptance contract with the TypeScript grant signer
// (libs/connector-protocol, owned by I1).
//
// A grant is ed25519 over the EXACT std-base64 JSON bytes of the Grant struct
// in fixed field order {v,sid,conn,scan,cidrs,exp}. RFC 8032 ed25519 is
// deterministic, so Node `crypto.sign(null, raw, ed25519Key)` emits byte-for-byte
// the same signature `ed25519.Sign` does over the same `raw`; this Go verifier
// must accept it unchanged.
//
// The fixture below was produced by signing the canonical JSON with a fixed
// seed (so it is reproducible and carries no wall-clock dependency); it stands
// in for a real TS-emitted fixture until I1 lands one. To swap in the real
// fixture, replace the three constants with the std-base64 strings I1's signer
// emits for the same Grant and keep the asserted fields in sync.
const (
	// std-base64 of {"v":1,"sid":"sid-fixture","conn":"conn-fixture","scan":"scan-fixture","cidrs":["10.0.0.0/8","192.168.1.5"],"exp":4102444800}
	fixtureGrantB64 = "eyJ2IjoxLCJzaWQiOiJzaWQtZml4dHVyZSIsImNvbm4iOiJjb25uLWZpeHR1cmUiLCJzY2FuIjoic2Nhbi1maXh0dXJlIiwiY2lkcnMiOlsiMTAuMC4wLjAvOCIsIjE5Mi4xNjguMS41Il0sImV4cCI6NDEwMjQ0NDgwMH0="
	// std-base64 of the 64-byte ed25519 signature over those exact bytes.
	fixtureSigB64 = "MKEJYcU+Ub+sImuzfXuZNzMnNn5U0Jpy9gNuPwW9XWlJC4LXHFiB3NGkk/I72CgRb8qsfOs+NtPg6UbxKtslDw=="
	// std-base64 of the raw 32-byte ed25519 public key (the enrollment grantKey).
	fixturePubB64 = "ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ="
)

// fixtureNow is any instant before the fixture's exp (unix 4102444800, 2100-01-01),
// pinned so the test never depends on the wall clock.
var fixtureNow = time.Unix(1790000000, 0)

func TestVerifyAcceptsCrossLangFixture(t *testing.T) {
	pub, err := base64.StdEncoding.DecodeString(fixturePubB64)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		t.Fatalf("bad fixture public key: %v (len %d)", err, len(pub))
	}
	v, err := Verify(ed25519.PublicKey(pub), fixtureGrantB64, fixtureSigB64, "conn-fixture", fixtureNow)
	if err != nil {
		t.Fatalf("cross-language grant rejected: %v", err)
	}
	if v.V != 1 || v.Sid != "sid-fixture" || v.Conn != "conn-fixture" || v.Scan != "scan-fixture" {
		t.Fatalf("unexpected fields: %+v", v.Grant)
	}
	if len(v.Scope.Prefixes()) != 2 {
		t.Fatalf("expected 2 scope prefixes, got %d", len(v.Scope.Prefixes()))
	}
	for _, in := range []string{"10.1.2.3", "192.168.1.5"} {
		if !v.Scope.Allows(mustAddr(t, in)) {
			t.Fatalf("in-scope address %s must be allowed", in)
		}
	}
	for _, out := range []string{"192.168.1.6", "8.8.8.8", "127.0.0.1"} {
		if v.Scope.Allows(mustAddr(t, out)) {
			t.Fatalf("out-of-scope address %s must be denied", out)
		}
	}
}

// TestVerifyRejectsWrongConnectorCrossLang pins that the fixture is connector-bound.
func TestVerifyRejectsWrongConnectorCrossLang(t *testing.T) {
	pub, _ := base64.StdEncoding.DecodeString(fixturePubB64)
	if _, err := Verify(ed25519.PublicKey(pub), fixtureGrantB64, fixtureSigB64, "someone-else", fixtureNow); err == nil {
		t.Fatal("grant issued for conn-fixture must be rejected for another connector")
	}
}
