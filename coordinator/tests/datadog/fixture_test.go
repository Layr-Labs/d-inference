package datadog_test

import (
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/datadog"
)

func newTestClient(t *testing.T, cfg production.Config) *production.Client {
	t.Helper()
	if cfg.FlushSecs == 0 {
		cfg.FlushSecs = 3600
	}
	if cfg.StatsdClient == nil && cfg.StatsdAddr == "" {
		socket, err := net.ListenPacket("udp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = socket.Close() })
		cfg.StatsdAddr = socket.LocalAddr().String()
	}
	client, err := production.NewClient(cfg, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(client.Close)
	return client
}

type intakeTransport func(*http.Request) (*http.Response, error)

func (f intakeTransport) RoundTrip(req *http.Request) (*http.Response, error) { return f(req) }

func intakeClient(t *testing.T, server *httptest.Server) *http.Client {
	t.Helper()
	target, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	client := *server.Client()
	transport := client.Transport
	if transport == nil {
		transport = http.DefaultTransport
	}
	client.Transport = intakeTransport(func(req *http.Request) (*http.Response, error) {
		copy := req.Clone(req.Context())
		address := *req.URL
		address.Scheme, address.Host = target.Scheme, target.Host
		copy.URL = &address
		return transport.RoundTrip(copy)
	})
	return &client
}
