package auth_test

import (
	"bytes"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/auth"
)

// privyErrorBody stands in for a Privy error response that echoes request
// data. Coordinator errors and logs must not repeat it.
const (
	privyErrorEmail = "privy.echo@example.com"
	privyErrorBody  = `{"error":"rejected ` + privyErrorEmail + ` privy-body-marker"}`
)

// localPrivyTransport sends the fixed auth.privy.io requests to a local server.
type localPrivyTransport struct{ target *url.URL }

func (l localPrivyTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	r = r.Clone(r.Context())
	r.URL.Scheme, r.URL.Host, r.Host = l.target.Scheme, l.target.Host, l.target.Host
	return http.DefaultTransport.RoundTrip(r)
}

func rejectingPrivyClient(t *testing.T) *http.Client {
	t.Helper()
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(privyErrorBody))
	}))
	t.Cleanup(ts.Close)
	target, err := url.Parse(ts.URL)
	if err != nil {
		t.Fatal(err)
	}
	return &http.Client{Transport: localPrivyTransport{target: target}}
}

func assertOmitsPrivyBody(t *testing.T, what, text string) {
	t.Helper()
	for _, marker := range []string{privyErrorEmail, "privy-body-marker"} {
		if strings.Contains(text, marker) {
			t.Errorf("%s contains the Privy response body marker %q: %s", what, marker, text)
		}
	}
}

func TestPrivyOTPErrorsOmitUpstreamBody(t *testing.T) {
	_, pem := genES256Key(t)
	a := newAuth(t, pem, "test-secret", testMemStore(), rejectingPrivyClient(t))

	initErr := a.InitEmailOTP("admin@example.com")
	_, verifyErr := a.VerifyEmailOTP("admin@example.com", "123456")
	for name, err := range map[string]error{"init": initErr, "verify": verifyErr} {
		if err == nil || !strings.Contains(err.Error(), "400") {
			t.Fatalf("%s error = %v, want the Privy status code", name, err)
		}
		assertOmitsPrivyBody(t, name+" error", err.Error())
	}
}

func TestGetOrCreateUserLogOmitsPrivyResponseBody(t *testing.T) {
	_, pem := genES256Key(t)
	var logs bytes.Buffer
	a, err := production.NewPrivyAuth(production.Config{
		AppID: testAppID, AppSecret: "test-secret", VerificationKey: pem, HTTPClient: rejectingPrivyClient(t),
	}, testMemStore(), slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug})))
	if err != nil {
		t.Fatal(err)
	}

	if _, err := a.GetOrCreateUser("did:privy:log-body"); err != nil {
		t.Fatalf("GetOrCreateUser: %v", err)
	}
	if !strings.Contains(logs.String(), "failed to fetch user details") || !strings.Contains(logs.String(), "400") {
		t.Fatalf("missing user-details failure log with the status code:\n%s", logs.String())
	}
	assertOmitsPrivyBody(t, "log output", logs.String())
}
