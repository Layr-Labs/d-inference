package api_test

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const privyBodyMarker = "privy-body-marker"

// localPrivyTransport sends the fixed auth.privy.io requests to a local server.
type localPrivyTransport struct{ target *url.URL }

func (l localPrivyTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	r = r.Clone(r.Context())
	r.URL.Scheme, r.URL.Host, r.Host = l.target.Scheme, l.target.Host, l.target.Host
	return http.DefaultTransport.RoundTrip(r)
}

// rejectingPrivyAuth returns Privy auth whose upstream answers every call with
// 400 and a body that echoes the admin email.
func rejectingPrivyAuth(t *testing.T, st store.Store, logger *slog.Logger) *auth.PrivyAuth {
	t.Helper()
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = fmt.Fprintf(w, `{"error":"rejected %s %s"}`, logTestEmail, privyBodyMarker)
	}))
	t.Cleanup(ts.Close)
	target, err := url.Parse(ts.URL)
	if err != nil {
		t.Fatal(err)
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	pa, err := auth.NewPrivyAuth(auth.Config{
		AppID:           "test-privy-app",
		AppSecret:       "test-privy-secret",
		VerificationKey: string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})),
		HTTPClient:      &http.Client{Transport: localPrivyTransport{target: target}},
	}, st, logger)
	if err != nil {
		t.Fatal(err)
	}
	return pa
}

func TestAdminOTPFailureOmitsPrivyResponseBody(t *testing.T) {
	for _, tc := range []struct {
		path, body, errType string
		status              int
	}{
		{"/v1/admin/auth/init", fmt.Sprintf(`{"email":%q}`, logTestEmail), "otp_error", http.StatusInternalServerError},
		{"/v1/admin/auth/verify", fmt.Sprintf(`{"email":%q,"code":"123456"}`, logTestEmail), "auth_error", http.StatusUnauthorized},
	} {
		t.Run(tc.path, func(t *testing.T) {
			srv, st, logs := logCaptureServer(t)
			srv.SetPrivyAuth(rejectingPrivyAuth(t, st, slog.New(slog.DiscardHandler)))

			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, personalDataRequest(http.MethodPost, tc.path, tc.body))

			if w.Code != tc.status || !strings.Contains(w.Body.String(), `"`+tc.errType+`"`) {
				t.Fatalf("status = %d, body: %s; want %d %s", w.Code, w.Body.String(), tc.status, tc.errType)
			}
			for name, text := range map[string]string{"response": w.Body.String(), "log output": logs.String()} {
				if strings.Contains(text, privyBodyMarker) {
					t.Errorf("%s contains the Privy response body:\n%s", name, text)
				}
			}
			assertLogsOmitPersonalData(t, logs)
		})
	}
}
