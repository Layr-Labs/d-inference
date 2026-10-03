package api

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/profilesign"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/smallstep/pkcs7"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	pkcs12 "software.sslmate.com/src/go-pkcs12"
	"strings"
	"testing"
	"time"
)

func enrollTestServer(t *testing.T) *Server {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	st := memory.NewMemory(store.Config{})
	return NewServer(reg, st, ServerConfig{}, logger)
}

func TestHandleEnrollEndpoint(t *testing.T) {
	srv := enrollTestServer(t)

	// A legacy serial field is accepted for rollout compatibility but ignored.
	body := `{"serial_number": "PRIVATE-SERIAL"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/enroll", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Host = "api.darkbloom.dev"
	req.Header.Set("X-Forwarded-Proto", "https")

	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	if ct := w.Header().Get("Content-Type"); ct != "application/x-apple-aspen-config" {
		t.Errorf("expected mobileconfig content type, got %s", ct)
	}

	if cd := w.Header().Get("Content-Disposition"); cd != `attachment; filename="Darkbloom-Enroll.mobileconfig"` {
		t.Errorf("expected privacy-safe Darkbloom download filename, got %q", cd)
	} else if strings.Contains(cd, "PRIVATE-SERIAL") {
		t.Errorf("download filename exposed device serial: %q", cd)
	}

	profile := w.Body.String()
	if strings.Contains(profile, "PRIVATE-SERIAL") || strings.Contains(profile, "serial_number") {
		t.Fatal("enrollment profile exposed legacy request identity")
	}

	// Verify URLs use the request host
	if !strings.Contains(profile, "https://api.darkbloom.dev/scep") {
		t.Error("profile SCEP URL doesn't match request host")
	}
	if !strings.Contains(profile, "https://api.darkbloom.dev/mdm/checkin") {
		t.Error("profile CheckInURL doesn't match request host")
	}
}

// newTestProfileSigner builds an ephemeral self-signed code-signing identity and
// wraps it in a profilesign.Signer for use in enrollment tests.
func newTestProfileSigner(t *testing.T) *profilesign.Signer {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(42),
		Subject: pkix.Name{
			CommonName:   "Darkbloom Enrollment Signer",
			Organization: []string{"Darkbloom"},
		},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageCodeSigning},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatalf("parse certificate: %v", err)
	}
	p12, err := pkcs12.Modern.Encode(key, cert, nil, "test")
	if err != nil {
		t.Fatalf("encode pkcs12: %v", err)
	}
	signer, err := profilesign.NewSigner(p12, "test")
	if err != nil {
		t.Fatalf("NewSigner: %v", err)
	}
	return signer
}

// TestHandleEnrollSigned verifies that when a profile signer is configured, the
// served body is a CMS SignedData wrapping the exact same plist the unsigned path
// would serve, signed by the configured identity.
func TestHandleEnrollSigned(t *testing.T) {
	srv := enrollTestServer(t)
	srv.SetProfileSigner(newTestProfileSigner(t))

	body := `{}`
	req := httptest.NewRequest(http.MethodPost, "/v1/enroll", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Host = "api.darkbloom.dev"
	req.Header.Set("X-Forwarded-Proto", "https")

	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	// Signed profiles keep the same MIME type.
	if ct := w.Header().Get("Content-Type"); ct != "application/x-apple-aspen-config" {
		t.Errorf("expected mobileconfig content type, got %s", ct)
	}

	// The body must NOT be raw XML anymore — it's binary DER CMS.
	if strings.HasPrefix(w.Body.String(), "<?xml") {
		t.Fatal("expected signed (CMS/DER) body, got raw XML plist")
	}

	p7, err := pkcs7.Parse(w.Body.Bytes())
	if err != nil {
		t.Fatalf("served profile is not valid PKCS7/CMS: %v", err)
	}

	// Encapsulated content must be the plist with the expected payloads + host.
	content := string(p7.Content)
	if !strings.HasPrefix(content, `<?xml version="1.0"`) {
		t.Error("encapsulated content is not an XML plist")
	}
	for _, want := range []string{
		"com.apple.security.scep",
		"com.apple.mdm",
		"https://api.darkbloom.dev/scep",
		"<string>io.darkbloom.enroll</string>",
	} {
		if !strings.Contains(content, want) {
			t.Errorf("encapsulated profile missing %q", want)
		}
	}

	// Signed by the configured identity.
	if signer := p7.GetOnlySigner(); signer == nil || signer.Subject.CommonName != "Darkbloom Enrollment Signer" {
		t.Errorf("unexpected signer cert: %+v", signer)
	}
}

// TestHandleEnrollUnsignedFallback verifies the historical behaviour: with no
// signer configured, the raw XML plist is served unchanged.
func TestHandleEnrollUnsignedFallback(t *testing.T) {
	srv := enrollTestServer(t) // no signer set

	body := `{}`
	req := httptest.NewRequest(http.MethodPost, "/v1/enroll", strings.NewReader(body))
	req.Host = "api.darkbloom.dev"
	req.Header.Set("X-Forwarded-Proto", "https")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	if !strings.HasPrefix(w.Body.String(), `<?xml version="1.0"`) {
		t.Error("expected raw XML plist when no signer configured")
	}
}

// TestHandleEnrollPinsCanonicalBaseURL is a regression for the P1 finding: when a
// canonical base URL is configured, a spoofed Host header must NOT end up in the
// (signed) profile's SCEP/MDM URLs — otherwise an attacker could obtain a
// Darkbloom-signed profile pointing enrollment at their own host.
func TestHandleEnrollPinsCanonicalBaseURL(t *testing.T) {
	srv := enrollTestServer(t)
	srv.SetBaseURL("https://api.darkbloom.dev")
	srv.SetProfileSigner(newTestProfileSigner(t))

	req := httptest.NewRequest(http.MethodPost, "/v1/enroll", strings.NewReader(`{}`))
	req.Host = "evil.example.com" // spoofed Host header
	req.Header.Set("X-Forwarded-Proto", "https")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	p7, err := pkcs7.Parse(w.Body.Bytes())
	if err != nil {
		t.Fatalf("served profile is not valid PKCS7/CMS: %v", err)
	}
	content := string(p7.Content)
	if !strings.Contains(content, "https://api.darkbloom.dev/scep") {
		t.Error("signed profile did not use the configured canonical base URL")
	}
	if strings.Contains(content, "evil.example.com") {
		t.Error("spoofed Host header leaked into the signed profile")
	}
}

func TestHandleEnrollRejectsInvalidJSON(t *testing.T) {
	srv := enrollTestServer(t)

	req := httptest.NewRequest(http.MethodPost, "/v1/enroll", strings.NewReader(`{`))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", w.Code)
	}

	var resp map[string]interface{}
	json.Unmarshal(w.Body.Bytes(), &resp)
	errObj, ok := resp["error"].(map[string]interface{})
	if !ok {
		t.Fatal("expected error object in response")
	}
	if errObj["type"] != "invalid_request_error" {
		t.Errorf("expected invalid_request_error, got %v", errObj["type"])
	}
}
