package scope

import (
	"net/netip"
	"testing"
)

func TestDeniesReservedEvenWhenGranted(t *testing.T) {
	// A grant can never cover loopback / link-local (cloud metadata) / multicast.
	s, err := Parse([]string{"169.254.0.0/16"})
	if err == nil {
		t.Fatalf("link-local grant must be rejected, got %v", s)
	}
	s, err = Parse([]string{"10.0.0.0/8"})
	if err != nil {
		t.Fatalf("valid grant rejected: %v", err)
	}
	for _, ip := range []string{"169.254.169.254", "127.0.0.1", "10.255.255.254"} {
		a := mustAddr(t, ip)
		if ip == "10.255.255.254" && !s.Allows(a) {
			t.Fatalf("in-grant address %s must be allowed", ip)
		}
		if ip != "10.255.255.254" && s.Allows(a) {
			t.Fatalf("reserved address %s must be denied even inside a grant", ip)
		}
	}
}

func TestRejectsTooBroad(t *testing.T) {
	for _, cidr := range []string{"0.0.0.0/0", "10.0.0.0/7", "::/0"} {
		if _, err := Parse([]string{cidr}); err == nil {
			t.Fatalf("over-broad CIDR %s must be rejected", cidr)
		}
	}
}

func TestBareIPMeansSingleHost(t *testing.T) {
	s, err := Parse([]string{"192.168.1.10"})
	if err != nil {
		t.Fatal(err)
	}
	if !s.Allows(mustAddr(t, "192.168.1.10")) {
		t.Fatal("granted host must be allowed")
	}
	if s.Allows(mustAddr(t, "192.168.1.11")) {
		t.Fatal("neighbour host must NOT be allowed")
	}
}

func TestEmptyScopeRejected(t *testing.T) {
	if _, err := Parse(nil); err == nil {
		t.Fatal("empty scope must be rejected")
	}
}

func mustAddr(t *testing.T, ip string) netip.Addr {
	t.Helper()
	a, err := netip.ParseAddr(ip)
	if err != nil {
		t.Fatal(err)
	}
	return a
}
