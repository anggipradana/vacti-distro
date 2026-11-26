package main

import (
	"bytes"
	"io"
	"net"
	"testing"
	"time"
)

// TestSocksGreetingMultipleMethods drives the SOCKS5 handshake the way curl
// built with GSSAPI does (two offered methods). The CONNECT that follows must
// be parsed correctly: here it targets a bad address type, so the server must
// answer with a SOCKS reply (VER=5), not reset the connection.
func TestSocksGreetingMultipleMethods(t *testing.T) {
	for _, greet := range [][]byte{
		{5, 1, 0},       // one method (what x/net/proxy sends)
		{5, 2, 0, 1},    // no-auth + GSSAPI (curl with krb5)
		{5, 3, 0, 1, 2}, // no-auth + GSSAPI + user/pass
	} {
		client, server := net.Pipe()
		tun := &tunnel{relay: "ws://127.0.0.1:1", token: "x"}
		go tun.socks(server)
		_ = client.SetDeadline(time.Now().Add(5 * time.Second))
		if _, err := client.Write(greet); err != nil {
			t.Fatalf("%v: write greeting: %v", greet, err)
		}
		sel := make([]byte, 2)
		if _, err := io.ReadFull(client, sel); err != nil || !bytes.Equal(sel, []byte{5, 0}) {
			t.Fatalf("%v: method selection = %v, %v; want [5 0]", greet, sel, err)
		}
		// CONNECT with an unsupported ATYP (9): a correctly framed request gets
		// a general-failure reply.
		if _, err := client.Write([]byte{5, 1, 0, 9}); err != nil {
			t.Fatalf("%v: write connect: %v", greet, err)
		}
		rep := make([]byte, 2)
		if _, err := io.ReadFull(client, rep); err != nil || rep[0] != 5 || rep[1] == 0 {
			t.Fatalf("%v: connect reply = %v, %v; want a SOCKS5 failure reply", greet, rep, err)
		}
		client.Close()
	}
}

// TestSocksGreetingWithoutNoAuth refuses a client that does not offer no-auth.
func TestSocksGreetingWithoutNoAuth(t *testing.T) {
	client, server := net.Pipe()
	tun := &tunnel{relay: "ws://127.0.0.1:1", token: "x"}
	go tun.socks(server)
	_ = client.SetDeadline(time.Now().Add(5 * time.Second))
	_, _ = client.Write([]byte{5, 1, 2})
	sel := make([]byte, 2)
	if _, err := io.ReadFull(client, sel); err != nil || !bytes.Equal(sel, []byte{5, 0xff}) {
		t.Fatalf("selection = %v, %v; want [5 255]", sel, err)
	}
}
