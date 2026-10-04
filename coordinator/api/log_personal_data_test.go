package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Process logs are forwarded to Datadog, so erasing an account in the store
// does not erase them. These tests capture every log line (Debug and up) that a
// request produces and check that no personal data reaches it.

const (
	logTestEmail      = "erasable.person@example.com"
	logTestRemoteIP   = "203.0.113.77"
	logTestForwardIP  = "198.51.100.23"
	logTestDeviceUDID = "00008112-001A2B3C4D5E6F70"
)

func logCaptureServer(t *testing.T) (*Server, *store.MemoryStore, *bytes.Buffer) {
	t.Helper()
	var buf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	t.Cleanup(srv.Close)
	srv.SetAdminKey("admin-secret")
	return srv, st, &buf
}

func personalDataRequest(method, path, body string) *http.Request {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.RemoteAddr = logTestRemoteIP + ":4242"
	req.Header.Set("X-Forwarded-For", logTestForwardIP)
	return req
}

func assertLogsOmitPersonalData(t *testing.T, logs *bytes.Buffer) {
	t.Helper()
	if logs.Len() == 0 {
		t.Fatal("no log output captured; the test would pass vacuously")
	}
	for _, value := range []string{logTestEmail, logTestRemoteIP, logTestForwardIP, logTestDeviceUDID} {
		if strings.Contains(logs.String(), value) {
			t.Errorf("log output contains personal data %q:\n%s", value, logs.String())
		}
	}
}

func TestAdminCreditLogsOmitPersonalData(t *testing.T) {
	srv, st, logs := logCaptureServer(t)
	user := seedUser(t, st, "acct-log-credit", logTestEmail)

	body := fmt.Sprintf(`{"email":%q,"amount_usd":"5.00","note":"log test"}`, logTestEmail)
	req := personalDataRequest(http.MethodPost, "/v1/admin/credit", body)
	req.Header.Set("Authorization", "Bearer admin-secret")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, body: %s", w.Code, w.Body.String())
	}
	if !strings.Contains(logs.String(), user.AccountID) {
		t.Errorf("credit log should identify the account by account_id:\n%s", logs.String())
	}
	assertLogsOmitPersonalData(t, logs)
}

func TestDeviceApproveLogsOmitPersonalData(t *testing.T) {
	srv, _, logs := logCaptureServer(t)

	codeW := httptest.NewRecorder()
	srv.handleDeviceCode(codeW, httptest.NewRequest(http.MethodPost, "/v1/device/code", nil))
	var codeResp map[string]any
	if err := json.Unmarshal(codeW.Body.Bytes(), &codeResp); err != nil {
		t.Fatalf("device code response: %v", err)
	}

	body := fmt.Sprintf(`{"user_code":%q}`, codeResp["user_code"])
	req := personalDataRequest(http.MethodPost, "/v1/device/approve", body)
	req = req.WithContext(withUser(req.Context(), "acct-log-device", logTestEmail))
	w := httptest.NewRecorder()
	srv.loggingMiddleware(http.HandlerFunc(srv.handleDeviceApprove)).ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, body: %s", w.Code, w.Body.String())
	}
	if !strings.Contains(logs.String(), "acct-log-device") {
		t.Errorf("approve log should identify the account by account_id:\n%s", logs.String())
	}
	assertLogsOmitPersonalData(t, logs)
}

func TestMDMWebhookLogsOmitPersonalData(t *testing.T) {
	srv, _, logs := logCaptureServer(t)
	srv.SetMDMWebhookSecret("webhook-secret")

	rejected := personalDataRequest(http.MethodPost, "/v1/mdm/webhook", "{}")
	rejected.Header.Set("X-Webhook-Token", "wrong")
	srv.Handler().ServeHTTP(httptest.NewRecorder(), rejected)

	accepted := personalDataRequest(http.MethodPost, "/v1/mdm/webhook",
		fmt.Sprintf(`{"topic":"mdm.Connect","acknowledge_event":{"udid":%q}}`, logTestDeviceUDID))
	accepted.Header.Set("X-Webhook-Token", "webhook-secret")
	srv.Handler().ServeHTTP(httptest.NewRecorder(), accepted)

	for _, want := range []string{"mdm webhook rejected", "mdm webhook received"} {
		if !strings.Contains(logs.String(), want) {
			t.Errorf("missing log line %q:\n%s", want, logs.String())
		}
	}
	assertLogsOmitPersonalData(t, logs)
}

func TestRejectedStateExportLogsOmitPersonalData(t *testing.T) {
	srv, _, logs := logCaptureServer(t)
	t.Setenv(envStateExportEnabled, "true")

	export := personalDataRequest(http.MethodGet, "/v1/admin/state-export", "")
	export.Header.Set("Authorization", "Bearer wrong")
	srv.Handler().ServeHTTP(httptest.NewRecorder(), export)

	if want := "state-export: unauthorized access attempt"; !strings.Contains(logs.String(), want) {
		t.Errorf("missing log line %q:\n%s", want, logs.String())
	}
	assertLogsOmitPersonalData(t, logs)
}
