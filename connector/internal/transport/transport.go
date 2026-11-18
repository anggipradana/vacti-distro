// Package transport turns a WebSocket into a yamux session.
package transport

import (
	"context"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/hashicorp/yamux"
)

// YamuxConfig is shared by every peer so keepalives line up.
func YamuxConfig() *yamux.Config {
	c := yamux.DefaultConfig()
	c.AcceptBacklog = 1024
	c.EnableKeepAlive = true
	c.KeepAliveInterval = 20 * time.Second
	c.ConnectionWriteTimeout = 30 * time.Second
	c.MaxStreamWindowSize = 1 << 20
	c.LogOutput = io.Discard
	return c
}

// Dial opens a WebSocket to url with the given headers and returns it as a
// net.Conn. The returned http status is set when the server refused the upgrade.
//
// IPv4 fallback: customer networks (and this laptop's) are often IPv4-only,
// while a relay hostname behind Cloudflare answers AAAA first — Go's dial can
// then abort on "no route to host" without ever trying A. On exactly those
// routing failures we retry once with a tcp4-only client.
func Dial(ctx context.Context, url string, header http.Header) (net.Conn, int, error) {
	dctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	c, resp, err := websocket.Dial(dctx, url, &websocket.DialOptions{HTTPHeader: header})
	if err != nil && isRoutingFailure(err) {
		dctx2, cancel2 := context.WithTimeout(ctx, 20*time.Second)
		defer cancel2()
		c2, resp2, err2 := websocket.Dial(dctx2, url, &websocket.DialOptions{
			HTTPHeader: header,
			HTTPClient: ipv4OnlyClient(),
		})
		if err2 == nil {
			c2.SetReadLimit(-1)
			return websocket.NetConn(context.Background(), c2, websocket.MessageBinary), 0, nil
		}
		if resp2 != nil {
			resp = resp2
		}
		err = err2
	}
	if err != nil {
		status := 0
		if resp != nil {
			status = resp.StatusCode
		}
		return nil, status, err
	}
	c.SetReadLimit(-1)
	return websocket.NetConn(context.Background(), c, websocket.MessageBinary), 0, nil
}

func isRoutingFailure(err error) bool {
	msg := err.Error()
	return strings.Contains(msg, "no route to host") ||
		strings.Contains(msg, "network is unreachable")
}

func ipv4OnlyClient() *http.Client {
	d := &net.Dialer{Timeout: 20 * time.Second}
	return &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return d.DialContext(ctx, "tcp4", addr)
			},
		},
	}
}

// Accept upgrades an HTTP request to a WebSocket net.Conn.
func Accept(w http.ResponseWriter, r *http.Request) (net.Conn, error) {
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// Peers are programs, not browsers; there is no Origin to check.
		InsecureSkipVerify: true,
	})
	if err != nil {
		return nil, err
	}
	c.SetReadLimit(-1)
	return websocket.NetConn(context.Background(), c, websocket.MessageBinary), nil
}

// Pipe copies both directions until either side closes, then closes both.
func Pipe(a, b io.ReadWriteCloser) {
	done := make(chan struct{}, 2)
	cp := func(dst io.WriteCloser, src io.Reader) {
		_, _ = io.Copy(dst, src)
		switch d := dst.(type) {
		case interface{ CloseWrite() error }:
			_ = d.CloseWrite()
		case *yamux.Stream:
			// yamux Close is a half-close: it sends FIN and keeps reading.
			_ = d.Close()
		}
		done <- struct{}{}
	}
	go cp(a, b)
	go cp(b, a)
	<-done
	// Give the other direction a moment to drain a half-close, then tear down.
	select {
	case <-done:
	case <-time.After(30 * time.Second):
	}
	_ = a.Close()
	_ = b.Close()
}
