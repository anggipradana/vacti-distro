// Package scope decides which destinations a session may reach.
//
// A destination is allowed only when it falls inside one of the session's
// granted prefixes AND is not in the hard deny list (loopback, link-local
// incl. cloud metadata, unspecified, multicast, broadcast). The deny list wins
// even when a grant would cover the address.
package scope

import (
	"fmt"
	"net/netip"
)

var denied = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("127.0.0.0/8"),
	netip.MustParsePrefix("169.254.0.0/16"),
	netip.MustParsePrefix("224.0.0.0/4"),
	netip.MustParsePrefix("255.255.255.255/32"),
	netip.MustParsePrefix("::/128"),
	netip.MustParsePrefix("::1/128"),
	netip.MustParsePrefix("fe80::/10"),
	netip.MustParsePrefix("ff00::/8"),
}

// MinPrefixBitsV4 / V6 reject absurdly broad grants (e.g. 0.0.0.0/0), which
// would also swallow the scan device's own control-plane traffic.
const (
	MinPrefixBitsV4 = 8
	MinPrefixBitsV6 = 32
)

// Set is an immutable list of allowed prefixes.
type Set struct{ prefixes []netip.Prefix }

// Parse builds a Set from CIDR strings (a bare IP means a single host).
func Parse(cidrs []string) (Set, error) {
	out := make([]netip.Prefix, 0, len(cidrs))
	for _, c := range cidrs {
		p, err := ParsePrefix(c)
		if err != nil {
			return Set{}, err
		}
		out = append(out, p)
	}
	if len(out) == 0 {
		return Set{}, fmt.Errorf("empty scope")
	}
	return Set{prefixes: out}, nil
}

// ParsePrefix parses and validates one CIDR or bare IP.
func ParsePrefix(c string) (netip.Prefix, error) {
	var p netip.Prefix
	if addr, err := netip.ParseAddr(c); err == nil {
		p = netip.PrefixFrom(addr, addr.BitLen())
	} else {
		p, err = netip.ParsePrefix(c)
		if err != nil {
			return netip.Prefix{}, fmt.Errorf("invalid CIDR %q", c)
		}
	}
	p = p.Masked()
	min := MinPrefixBitsV4
	if p.Addr().Is6() && !p.Addr().Is4In6() {
		min = MinPrefixBitsV6
	}
	if p.Bits() < min {
		return netip.Prefix{}, fmt.Errorf("CIDR %q is too broad (minimum /%d)", c, min)
	}
	for _, d := range denied {
		if d.Contains(p.Addr()) && d.Bits() <= p.Bits() {
			return netip.Prefix{}, fmt.Errorf("CIDR %q is in a reserved range", c)
		}
	}
	return p, nil
}

// Prefixes returns a copy of the allowed prefixes.
func (s Set) Prefixes() []netip.Prefix { return append([]netip.Prefix(nil), s.prefixes...) }

// Denied reports whether addr is in the hard deny list.
func Denied(addr netip.Addr) bool {
	addr = addr.Unmap()
	for _, d := range denied {
		if d.Contains(addr) {
			return true
		}
	}
	return false
}

// Allows reports whether addr may be reached under this set.
func (s Set) Allows(addr netip.Addr) bool {
	addr = addr.Unmap()
	if !addr.IsValid() || Denied(addr) {
		return false
	}
	for _, p := range s.prefixes {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}
