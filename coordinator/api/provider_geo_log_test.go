package api

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

type failedGeoTransport struct{ err error }

func (f failedGeoTransport) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, f.err
}

func TestGeoLookupFailureOmitsKeyedRequestURL(t *testing.T) {
	for _, cause := range []error{errors.New("geo transport unavailable"), context.DeadlineExceeded} {
		t.Run(cause.Error(), func(t *testing.T) {
			var logs bytes.Buffer
			const key = "local-fixture geo&key"
			g := &ipAPIGeoResolver{
				apiKey: key, baseURL: ipAPIProBaseURL,
				httpClient: &http.Client{Transport: failedGeoTransport{err: cause}},
				logger:     slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug})),
			}
			if loc := g.lookupIPAPI(net.ParseIP("198.51.100.42")); loc != nil {
				t.Fatalf("failed lookup returned location: %+v", loc)
			}
			output := logs.String()
			for _, secret := range []string{key, url.QueryEscape(key)} {
				if strings.Contains(output, secret) {
					t.Fatal("geo lookup error logged the API key")
				}
			}
			if strings.Contains(output, "/json/") || strings.Contains(output, "fields=") {
				t.Fatal("geo lookup error logged the request URL")
			}
			if !strings.Contains(output, cause.Error()) || !strings.Contains(output, "pro=true") {
				t.Fatalf("missing transport cause or tier: %s", output)
			}
		})
	}
}
