package api

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
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
	st := store.NewMemory("")
	return NewServer(reg, st, logger)
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

	profile := w.Body.String()

	// Verify URLs use the request host
	if !strings.Contains(profile, "https://api.darkbloom.dev/scep") {
		t.Error("profile SCEP URL doesn't match request host")
	}
	if !strings.Contains(profile, "https://api.darkbloom.dev/mdm/checkin") {
		t.Error("profile CheckInURL doesn't match request host")
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
