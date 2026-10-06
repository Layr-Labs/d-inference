package geo_test

import (
	"bytes"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/geo"
)

type failingTransport struct{}

func (failingTransport) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, errors.New("connection reset by peer")
}

// http.Client wraps a transport failure in a *url.Error that holds the full
// lookup URL: the provider IP in the path and the PRO key in the query.
func TestLookupTransportFailureLogOmitsProviderIPAndKey(t *testing.T) {
	const providerIP = "203.0.113.91"
	const apiKey = "ipapi-key-marker-5c1e"
	var logs bytes.Buffer
	g := production.NewResolver(production.Config{
		APIKey:     apiKey,
		BaseURL:    "http://ip-api.test",
		HTTPClient: &http.Client{Transport: failingTransport{}},
		Logger:     slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug})),
	})
	r := httptest.NewRequest(http.MethodGet, "/v1/providers/ws", nil)
	r.RemoteAddr = providerIP + ":4242"

	if loc := g.Lookup(r); loc != nil {
		t.Fatalf("lookup with a failing transport returned %#v", loc)
	}
	if !strings.Contains(logs.String(), "ip-api lookup failed") {
		t.Fatalf("no lookup failure log line; the test would pass vacuously:\n%s", logs.String())
	}
	for _, marker := range []string{providerIP, apiKey} {
		if strings.Contains(logs.String(), marker) {
			t.Errorf("log output contains %q:\n%s", marker, logs.String())
		}
	}
}
