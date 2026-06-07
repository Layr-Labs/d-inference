package api

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/profilesign"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/smallstep/pkcs7"
	pkcs12 "software.sslmate.com/src/go-pkcs12"
)

func TestGenerateCombinedProfile(t *testing.T) {
	serial := "ABCD1234EFGH"
	baseURL := "https://api.darkbloom.dev"

	profile := generateCombinedProfile(serial, baseURL)

	// Must contain all 4 domain-specific URLs with the correct base
	expectedURLs := []string{
		"https://api.darkbloom.dev/scep",
		"https://api.darkbloom.dev/mdm/checkin",
		"https://api.darkbloom.dev/mdm/connect",
		"https://api.darkbloom.dev/acme/eigeninference-acme/directory",
	}
	for _, url := range expectedURLs {
		if !strings.Contains(profile, url) {
			t.Errorf("profile missing URL: %s", url)
		}
	}

	// Must NOT contain the old hardcoded domain
	if strings.Contains(profile, "inference-test.openinnovation.dev") {
		t.Error("profile still contains old hardcoded domain")
	}

	// Must contain serial number in payload identifiers
	if !strings.Contains(profile, "io.darkbloom.enroll.acme."+serial) {
		t.Error("profile missing ACME payload identifier with serial")
	}
	if !strings.Contains(profile, "io.darkbloom.enroll."+serial) {
		t.Error("profile missing profile identifier with serial")
	}

	// Must contain the push topic
	if !strings.Contains(profile, "com.apple.mgmt.External.10520cbe-9635-453d-ac4e-c79aab56f8ce") {
		t.Error("profile missing MDM push topic")
	}

	// Must be valid XML plist
	if !strings.HasPrefix(profile, `<?xml version="1.0"`) {
		t.Error("profile is not valid XML plist")
	}

	// Must contain all three payload types
	for _, payloadType := range []string{
		"com.apple.security.scep",
		"com.apple.mdm",
		"com.apple.security.acme",
	} {
		if !strings.Contains(profile, payloadType) {
			t.Errorf("profile missing payload type: %s", payloadType)
		}
	}

	// Display strings are rebranded to Darkbloom. The capitalized "EigenInference"
	// must be gone from all visible fields (PayloadOrganization, SCEP subject,
	// display names). The lowercase "eigeninference-acme" provisioner path stays
	// (functional step-ca identifier) and is asserted separately above.
	if strings.Contains(profile, "EigenInference") {
		t.Error("profile still contains capitalized 'EigenInference' display string")
	}
	if !strings.Contains(profile, "<string>Darkbloom</string>") {
		t.Error("profile missing Darkbloom PayloadOrganization")
	}
}

func TestGenerateCombinedProfileDifferentDomains(t *testing.T) {
	tests := []struct {
		name    string
		baseURL string
	}{
		{"production", "https://api.darkbloom.dev"},
		{"staging", "https://staging.darkbloom.dev"},
		{"localhost", "http://localhost:8080"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			profile := generateCombinedProfile("TEST1234", tt.baseURL)

			if !strings.Contains(profile, tt.baseURL+"/scep") {
				t.Errorf("expected SCEP URL with base %s", tt.baseURL)
			}
			if !strings.Contains(profile, tt.baseURL+"/mdm/checkin") {
				t.Errorf("expected CheckInURL with base %s", tt.baseURL)
			}
			if !strings.Contains(profile, tt.baseURL+"/mdm/connect") {
				t.Errorf("expected ServerURL with base %s", tt.baseURL)
			}
			if !strings.Contains(profile, tt.baseURL+"/acme/eigeninference-acme/directory") {
				t.Errorf("expected ACME DirectoryURL with base %s", tt.baseURL)
			}
		})
	}
}

func enrollTestServer(t *testing.T) *Server {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	st := store.NewMemory(store.Config{})
	return NewServer(reg, st, ServerConfig{}, logger)
}

func TestHandleEnrollEndpoint(t *testing.T) {
	srv := enrollTestServer(t)

	body := `{"serial_number": "ABCD1234EFGH"}`
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

	if cd := w.Header().Get("Content-Disposition"); !strings.Contains(cd, "Darkbloom-Enroll-") {
		t.Errorf("expected Darkbloom-branded download filename, got %q", cd)
	}

	profile := w.Body.String()

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

	body := `{"serial_number": "ABCD1234EFGH"}`
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
		"com.apple.security.acme",
		"https://api.darkbloom.dev/scep",
		"io.darkbloom.enroll.ABCD1234EFGH",
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

	body := `{"serial_number": "ABCD1234EFGH"}`
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
// (signed) profile's SCEP/MDM/ACME URLs — otherwise an attacker could obtain a
// Darkbloom-signed profile pointing enrollment at their own host.
func TestHandleEnrollPinsCanonicalBaseURL(t *testing.T) {
	srv := enrollTestServer(t)
	srv.SetBaseURL("https://api.darkbloom.dev")
	srv.SetProfileSigner(newTestProfileSigner(t))

	req := httptest.NewRequest(http.MethodPost, "/v1/enroll", strings.NewReader(`{"serial_number":"ABCD1234EFGH"}`))
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

func TestHandleEnrollInvalidSerial(t *testing.T) {
	srv := enrollTestServer(t)

	tests := []struct {
		name string
		body string
	}{
		{"empty", `{"serial_number": ""}`},
		{"too_short", `{"serial_number": "ABC"}`},
		{"lowercase", `{"serial_number": "abcd1234efgh"}`},
		{"special_chars", `{"serial_number": "ABCD-1234!"}`},
		{"missing_field", `{}`},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/v1/enroll", strings.NewReader(tt.body))
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			if w.Code != http.StatusBadRequest {
				t.Errorf("expected 400 for %s, got %d", tt.name, w.Code)
			}

			var resp map[string]interface{}
			json.Unmarshal(w.Body.Bytes(), &resp)
			errObj, ok := resp["error"].(map[string]interface{})
			if !ok {
				t.Errorf("expected error object in response")
				return
			}
			if errObj["type"] != "invalid_request_error" {
				t.Errorf("expected invalid_request_error, got %v", errObj["type"])
			}
		})
	}
}
