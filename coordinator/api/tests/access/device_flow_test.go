package access_test

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/access/device"
	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func deviceTestServer(t *testing.T) (*api.Server, store.Store) {
	t.Helper()
	fixture := testkit.New(t, api.ServerConfig{})
	return fixture.Server, fixture.Store
}

func TestDeviceCodeGeneration(t *testing.T) {
	srv, _ := deviceTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/v1/device/code", nil)
	w := httptest.NewRecorder()

	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body: %s", w.Code, w.Body.String())
	}

	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)

	dc := resp["device_code"].(string)
	if len(dc) != 64 {
		t.Errorf("device_code length = %d, want 64", len(dc))
	}

	uc := resp["user_code"].(string)
	if len(uc) != 9 || uc[4] != '-' {
		t.Errorf("user_code = %q, want XXXX-XXXX format", uc)
	}

	if _, ok := resp["verification_uri"]; !ok {
		t.Error("missing verification_uri")
	}
	if resp["expires_in"].(float64) != device.DeviceCodeExpiry.Seconds() {
		t.Errorf("expires_in = %v, want %v", resp["expires_in"], device.DeviceCodeExpiry.Seconds())
	}
	if resp["interval"].(float64) != device.DeviceCodePollInterval {
		t.Errorf("interval = %v, want %v", resp["interval"], device.DeviceCodePollInterval)
	}
}

func TestDeviceCodeUniquePerCall(t *testing.T) {
	srv, _ := deviceTestServer(t)
	seen := make(map[string]bool)

	for range 10 {
		req := httptest.NewRequest(http.MethodPost, "/v1/device/code", nil)
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)

		var resp map[string]any
		json.Unmarshal(w.Body.Bytes(), &resp)
		dc := resp["device_code"].(string)
		if seen[dc] {
			t.Error("duplicate device code generated")
		}
		seen[dc] = true
	}
}

func TestDeviceTokenPending(t *testing.T) {
	srv, _ := deviceTestServer(t)

	codeReq := httptest.NewRequest(http.MethodPost, "/v1/device/code", nil)
	codeW := httptest.NewRecorder()
	srv.Handler().ServeHTTP(codeW, codeReq)

	var codeResp map[string]any
	json.Unmarshal(codeW.Body.Bytes(), &codeResp)

	body := fmt.Sprintf(`{"device_code":"%s"}`, codeResp["device_code"].(string))
	tokenReq := httptest.NewRequest(http.MethodPost, "/v1/device/token", strings.NewReader(body))
	tokenW := httptest.NewRecorder()
	srv.Handler().ServeHTTP(tokenW, tokenReq)

	if tokenW.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", tokenW.Code)
	}
	var tokenResp map[string]any
	json.Unmarshal(tokenW.Body.Bytes(), &tokenResp)
	if tokenResp["status"] != "authorization_pending" {
		t.Errorf("status = %q, want authorization_pending", tokenResp["status"])
	}
}

func TestDeviceTokenNotFound(t *testing.T) {
	srv, _ := deviceTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/v1/device/token", strings.NewReader(`{"device_code":"nonexistent"}`))
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", w.Code)
	}
}

func TestDeviceTokenMissingField(t *testing.T) {
	srv, _ := deviceTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/v1/device/token", strings.NewReader(`{}`))
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", w.Code)
	}
}

func TestDeviceApproveAndTokenAuthorized(t *testing.T) {
	srv, st := deviceTestServer(t)
	sessionToken := testkit.NewSessions(t, srv, st).Token("acct-1")

	// Create device code.
	codeReq := httptest.NewRequest(http.MethodPost, "/v1/device/code", nil)
	codeW := httptest.NewRecorder()
	srv.Handler().ServeHTTP(codeW, codeReq)
	var codeResp map[string]any
	json.Unmarshal(codeW.Body.Bytes(), &codeResp)
	deviceCode := codeResp["device_code"].(string)
	userCode := codeResp["user_code"].(string)

	// Approve with a locally signed session token.
	approveBody := fmt.Sprintf(`{"user_code":"%s"}`, userCode)
	approveReq := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(approveBody))
	approveReq.Header.Set("Authorization", "Bearer "+sessionToken)
	approveW := httptest.NewRecorder()
	srv.Handler().ServeHTTP(approveW, approveReq)

	if approveW.Code != http.StatusOK {
		t.Fatalf("approve status = %d, body: %s", approveW.Code, approveW.Body.String())
	}

	// Poll token: should be authorized.
	tokenBody := fmt.Sprintf(`{"device_code":"%s"}`, deviceCode)
	tokenReq := httptest.NewRequest(http.MethodPost, "/v1/device/token", strings.NewReader(tokenBody))
	tokenW := httptest.NewRecorder()
	srv.Handler().ServeHTTP(tokenW, tokenReq)

	var tokenResp map[string]any
	json.Unmarshal(tokenW.Body.Bytes(), &tokenResp)
	if tokenResp["status"] != "authorized" {
		t.Errorf("status = %q, want authorized", tokenResp["status"])
	}
	token := tokenResp["token"].(string)
	if !strings.HasPrefix(token, "eigeninference-pt-") {
		t.Errorf("token = %q, want eigeninference-pt- prefix", token)
	}
	if tokenResp["account_id"] != "acct-1" {
		t.Errorf("account_id = %q, want acct-1", tokenResp["account_id"])
	}
}

func TestDeviceApproveRequiresAuth(t *testing.T) {
	srv, st := deviceTestServer(t)
	testkit.NewSessions(t, srv, st)
	req := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(`{"user_code":"ABCD-1234"}`))
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", w.Code)
	}
}

func TestDeviceApproveNotFound(t *testing.T) {
	srv, st := deviceTestServer(t)
	sessionToken := testkit.NewSessions(t, srv, st).Token("a1")
	req := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(`{"user_code":"ZZZZ-9999"}`))
	req.Header.Set("Authorization", "Bearer "+sessionToken)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", w.Code)
	}
}

func TestDeviceApproveAlreadyUsed(t *testing.T) {
	srv, st := deviceTestServer(t)
	sessionToken := testkit.NewSessions(t, srv, st).Token("a1")

	codeReq := httptest.NewRequest(http.MethodPost, "/v1/device/code", nil)
	codeW := httptest.NewRecorder()
	srv.Handler().ServeHTTP(codeW, codeReq)
	var codeResp map[string]any
	json.Unmarshal(codeW.Body.Bytes(), &codeResp)
	userCode := codeResp["user_code"].(string)

	body := fmt.Sprintf(`{"user_code":"%s"}`, userCode)

	// First approval.
	req1 := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(body))
	req1.Header.Set("Authorization", "Bearer "+sessionToken)
	w1 := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w1, req1)
	if w1.Code != http.StatusOK {
		t.Fatalf("first approve: %d", w1.Code)
	}

	// Second approval: conflict.
	req2 := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(body))
	req2.Header.Set("Authorization", "Bearer "+sessionToken)
	w2 := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w2, req2)
	if w2.Code != http.StatusConflict {
		t.Errorf("second approve status = %d, want 409", w2.Code)
	}
}

func TestDeviceTokenExpired(t *testing.T) {
	srv, st := deviceTestServer(t)
	st.CreateDeviceCode(&store.DeviceCode{
		DeviceCode: "expired-code-123",
		UserCode:   "EXPR-TEST",
		Status:     "pending",
		ExpiresAt:  time.Now().Add(-1 * time.Minute),
	})

	req := httptest.NewRequest(http.MethodPost, "/v1/device/token", strings.NewReader(`{"device_code":"expired-code-123"}`))
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusGone {
		t.Errorf("status = %d, want 410", w.Code)
	}
}

func TestDeviceApproveExpiredCode(t *testing.T) {
	srv, st := deviceTestServer(t)
	sessionToken := testkit.NewSessions(t, srv, st).Token("a1")
	st.CreateDeviceCode(&store.DeviceCode{
		DeviceCode: "expired-approve",
		UserCode:   "EXPX-TEST",
		Status:     "pending",
		ExpiresAt:  time.Now().Add(-1 * time.Minute),
	})

	req := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(`{"user_code":"EXPX-TEST"}`))
	req.Header.Set("Authorization", "Bearer "+sessionToken)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusGone {
		t.Errorf("status = %d, want 410", w.Code)
	}
}

func TestDeviceApproveCaseInsensitive(t *testing.T) {
	srv, st := deviceTestServer(t)
	sessionToken := testkit.NewSessions(t, srv, st).Token("a1")

	codeReq := httptest.NewRequest(http.MethodPost, "/v1/device/code", nil)
	codeW := httptest.NewRecorder()
	srv.Handler().ServeHTTP(codeW, codeReq)
	var codeResp map[string]any
	json.Unmarshal(codeW.Body.Bytes(), &codeResp)
	userCode := codeResp["user_code"].(string)

	// Approve with lowercase.
	body := fmt.Sprintf(`{"user_code":"%s"}`, strings.ToLower(userCode))
	req := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+sessionToken)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Errorf("lowercase approve status = %d, want 200", w.Code)
	}
}
