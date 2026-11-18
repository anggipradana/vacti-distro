package grant

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"testing"
	"time"
)

func signGrant(t *testing.T, g Grant) (string, string, ed25519.PublicKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(g)
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(raw),
		base64.StdEncoding.EncodeToString(ed25519.Sign(priv, raw)), pub
}

func baseGrant() Grant {
	return Grant{V: 1, Sid: "s1", Conn: "c1", Scan: "scan1", CIDRs: []string{"10.0.0.0/8"}, Exp: time.Now().Add(time.Hour).Unix()}
}

func TestVerifyHappyPath(t *testing.T) {
	gb, sig, pub := signGrant(t, baseGrant())
	v, err := Verify(pub, gb, sig, "c1", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if v.Sid != "s1" || len(v.Scope.Prefixes()) != 1 {
		t.Fatalf("unexpected verified grant %+v", v)
	}
}

func TestVerifyRejectsWrongConnector(t *testing.T) {
	gb, sig, pub := signGrant(t, baseGrant())
	if _, err := Verify(pub, gb, sig, "OTHER", time.Now()); err == nil {
		t.Fatal("grant for another connector must be rejected")
	}
}

func TestVerifyRejectsExpired(t *testing.T) {
	g := baseGrant()
	g.Exp = time.Now().Add(-time.Hour).Unix()
	gb, sig, pub := signGrant(t, g)
	if _, err := Verify(pub, gb, sig, "c1", time.Now()); err == nil {
		t.Fatal("expired grant must be rejected")
	}
}

func TestVerifyRejectsBadSignature(t *testing.T) {
	gb, _, pub := signGrant(t, baseGrant())
	_, sig2, _ := signGrant(t, baseGrant()) // signature from a different key
	if _, err := Verify(pub, gb, sig2, "c1", time.Now()); err == nil {
		t.Fatal("grant signed by another key must be rejected")
	}
}

func TestVerifyRejectsTamperedPayload(t *testing.T) {
	gb, sig, pub := signGrant(t, baseGrant())
	raw, _ := base64.StdEncoding.DecodeString(gb)
	var g Grant
	_ = json.Unmarshal(raw, &g)
	g.CIDRs = []string{"0.0.0.0/0"} // widen scope after signing
	tampered, _ := json.Marshal(g)
	if _, err := Verify(pub, base64.StdEncoding.EncodeToString(tampered), sig, "c1", time.Now()); err == nil {
		t.Fatal("tampered grant must fail signature check")
	}
}
