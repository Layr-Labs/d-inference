package apns_test

import (
	"context"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
)

// The push URL is /3/device/<token>. http.Client puts that URL in a transport
// error, and the push dispatcher logs the error.
func TestSendCodeChallengeTransportErrorOmitsDeviceToken(t *testing.T) {
	const deviceToken = "apnsdevicetokenmarker0123456789abcdef"
	provider, _ := e2e.GenerateSessionKeys()
	pub := base64.StdEncoding.EncodeToString(provider.PublicKey[:])
	nonce := base64.StdEncoding.EncodeToString([]byte("nonce-nonce-nonce-nonce-nonce-32"))
	ts := httptest.NewServer(http.NotFoundHandler())
	ts.Close()
	a := newTestAttestor(t, production.Config{HostOverride: ts.URL, HTTPClient: ts.Client()})

	result, err := a.SendCodeChallengeResult(context.Background(), deviceToken, "production", pub, nonce)
	if err == nil || result.Outcome() != "transport_error" {
		t.Fatalf("closed server: result %+v, err %v; want a transport error", result, err)
	}
	if !strings.Contains(err.Error(), "apns: send") {
		t.Fatalf("err = %v, want the send failure", err)
	}
	if strings.Contains(err.Error(), deviceToken) {
		t.Errorf("transport error contains the device token: %v", err)
	}
}
