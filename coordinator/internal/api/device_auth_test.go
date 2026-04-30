package api

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/darkbloom/coordinator/internal/auth"
	"github.com/darkbloom/coordinator/internal/registry"
	"github.com/darkbloom/coordinator/internal/store"
)

func deviceTestServer() (*Server, store.Store) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	return srv, st
}

func withUser(ctx context.Context, accountID, email string) context.Context {
	return context.WithValue(ctx, auth.CtxKeyUser, &store.User{
		AccountID: accountID,
		Email:     email,
	})
}

func TestDeviceCodeGeneration(t *testing.T) {
	srv, _ := deviceTestServer()
	req := httptest.NewRequest(http.MethodPost, "/v1/device/code", nil)
	w := httptest.NewRecorder()

	srv.handleDeviceCode(w, req)

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
	if resp["expires_in"].(float64) != DeviceCodeExpiry.Seconds() {
		t.Errorf("expires_in = %v, want %v", resp["expires_in"], DeviceCodeExpiry.Seconds())
	}
	if resp["interval"].(float64) != DeviceCodePollInterval {
		t.Errorf("interval = %v, want %v", resp["interval"], DeviceCodePollInterval)
	}
}

func TestDeviceCodeUniquePerCall(t *testing.T) {
	srv, _ := deviceTestServer()
	seen := make(map[string]bool)

	for range 10 {
		req := httptest.NewRequest(http.MethodPost, "/v1/device/code", nil)
		w := httptest.NewRecorder()
		srv.handleDeviceCode(w, req)

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
	srv, _ := deviceTestServer()

	codeReq := httptest.NewRequest(http.MethodPost, "/v1/device/code", nil)
	codeW := httptest.NewRecorder()
	srv.handleDeviceCode(codeW, codeReq)

	var codeResp map[string]any
	json.Unmarshal(codeW.Body.Bytes(), &codeResp)

	body := fmt.Sprintf(`{"device_code":"%s"}`, codeResp["device_code"].(string))
	tokenReq := httptest.NewRequest(http.MethodPost, "/v1/device/token", strings.NewReader(body))
	tokenW := httptest.NewRecorder()
	srv.handleDeviceToken(tokenW, tokenReq)

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
	srv, _ := deviceTestServer()
	req := httptest.NewRequest(http.MethodPost, "/v1/device/token", strings.NewReader(`{"device_code":"nonexistent"}`))
	w := httptest.NewRecorder()
	srv.handleDeviceToken(w, req)
	if w.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", w.Code)
	}
}

func TestDeviceTokenMissingField(t *testing.T) {
	srv, _ := deviceTestServer()
	req := httptest.NewRequest(http.MethodPost, "/v1/device/token", strings.NewReader(`{}`))
	w := httptest.NewRecorder()
	srv.handleDeviceToken(w, req)
	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", w.Code)
	}
}

func TestDeviceApproveAndTokenAuthorized(t *testing.T) {
	srv, _ := deviceTestServer()

	// Create device code.
	codeReq := httptest.NewRequest(http.MethodPost, "/v1/device/code", nil)
	codeW := httptest.NewRecorder()
	srv.handleDeviceCode(codeW, codeReq)
	var codeResp map[string]any
	json.Unmarshal(codeW.Body.Bytes(), &codeResp)
	deviceCode := codeResp["device_code"].(string)
	userCode := codeResp["user_code"].(string)

	// Approve with user context.
	approveBody := fmt.Sprintf(`{"user_code":"%s"}`, userCode)
	approveReq := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(approveBody))
	approveReq = approveReq.WithContext(withUser(approveReq.Context(), "acct-1", "user@test.com"))
	approveW := httptest.NewRecorder()
	srv.handleDeviceApprove(approveW, approveReq)

	if approveW.Code != http.StatusOK {
		t.Fatalf("approve status = %d, body: %s", approveW.Code, approveW.Body.String())
	}

	// Poll token — should be authorized.
	tokenBody := fmt.Sprintf(`{"device_code":"%s"}`, deviceCode)
	tokenReq := httptest.NewRequest(http.MethodPost, "/v1/device/token", strings.NewReader(tokenBody))
	tokenW := httptest.NewRecorder()
	srv.handleDeviceToken(tokenW, tokenReq)

	var tokenResp map[string]any
	json.Unmarshal(tokenW.Body.Bytes(), &tokenResp)
	if tokenResp["status"] != "authorized" {
		t.Errorf("status = %q, want authorized", tokenResp["status"])
	}
	token := tokenResp["token"].(string)
	if !strings.HasPrefix(token, "darkbloom-pt-") {
		t.Errorf("token = %q, want darkbloom-pt- prefix", token)
	}
	if tokenResp["account_id"] != "acct-1" {
		t.Errorf("account_id = %q, want acct-1", tokenResp["account_id"])
	}
}

func TestDeviceApproveRequiresAuth(t *testing.T) {
	srv, _ := deviceTestServer()
	req := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(`{"user_code":"ABCD-1234"}`))
	w := httptest.NewRecorder()
	srv.handleDeviceApprove(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", w.Code)
	}
}

func TestDeviceApproveNotFound(t *testing.T) {
	srv, _ := deviceTestServer()
	req := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(`{"user_code":"ZZZZ-9999"}`))
	req = req.WithContext(withUser(req.Context(), "a1", ""))
	w := httptest.NewRecorder()
	srv.handleDeviceApprove(w, req)
	if w.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", w.Code)
	}
}

func TestDeviceApproveAlreadyUsed(t *testing.T) {
	srv, _ := deviceTestServer()

	codeReq := httptest.NewRequest(http.MethodPost, "/v1/device/code", nil)
	codeW := httptest.NewRecorder()
	srv.handleDeviceCode(codeW, codeReq)
	var codeResp map[string]any
	json.Unmarshal(codeW.Body.Bytes(), &codeResp)
	userCode := codeResp["user_code"].(string)

	body := fmt.Sprintf(`{"user_code":"%s"}`, userCode)

	// First approval.
	req1 := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(body))
	req1 = req1.WithContext(withUser(req1.Context(), "a1", ""))
	w1 := httptest.NewRecorder()
	srv.handleDeviceApprove(w1, req1)
	if w1.Code != http.StatusOK {
		t.Fatalf("first approve: %d", w1.Code)
	}

	// Second approval — conflict.
	req2 := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(body))
	req2 = req2.WithContext(withUser(req2.Context(), "a1", ""))
	w2 := httptest.NewRecorder()
	srv.handleDeviceApprove(w2, req2)
	if w2.Code != http.StatusConflict {
		t.Errorf("second approve status = %d, want 409", w2.Code)
	}
}

func TestDeviceTokenExpired(t *testing.T) {
	srv, st := deviceTestServer()
	st.CreateDeviceCode(&store.DeviceCode{
		DeviceCode: "expired-code-123",
		UserCode:   "EXPR-TEST",
		Status:     "pending",
		ExpiresAt:  time.Now().Add(-1 * time.Minute),
	})

	req := httptest.NewRequest(http.MethodPost, "/v1/device/token", strings.NewReader(`{"device_code":"expired-code-123"}`))
	w := httptest.NewRecorder()
	srv.handleDeviceToken(w, req)
	if w.Code != http.StatusGone {
		t.Errorf("status = %d, want 410", w.Code)
	}
}

func TestDeviceApproveExpiredCode(t *testing.T) {
	srv, st := deviceTestServer()
	st.CreateDeviceCode(&store.DeviceCode{
		DeviceCode: "expired-approve",
		UserCode:   "EXPX-TEST",
		Status:     "pending",
		ExpiresAt:  time.Now().Add(-1 * time.Minute),
	})

	req := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(`{"user_code":"EXPX-TEST"}`))
	req = req.WithContext(withUser(req.Context(), "a1", ""))
	w := httptest.NewRecorder()
	srv.handleDeviceApprove(w, req)
	if w.Code != http.StatusGone {
		t.Errorf("status = %d, want 410", w.Code)
	}
}

func TestDeviceApproveCaseInsensitive(t *testing.T) {
	srv, _ := deviceTestServer()

	codeReq := httptest.NewRequest(http.MethodPost, "/v1/device/code", nil)
	codeW := httptest.NewRecorder()
	srv.handleDeviceCode(codeW, codeReq)
	var codeResp map[string]any
	json.Unmarshal(codeW.Body.Bytes(), &codeResp)
	userCode := codeResp["user_code"].(string)

	// Approve with lowercase.
	body := fmt.Sprintf(`{"user_code":"%s"}`, strings.ToLower(userCode))
	req := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(body))
	req = req.WithContext(withUser(req.Context(), "a1", ""))
	w := httptest.NewRecorder()
	srv.handleDeviceApprove(w, req)
	if w.Code != http.StatusOK {
		t.Errorf("lowercase approve status = %d, want 200", w.Code)
	}
}

func TestGenerateUserCodeFormat(t *testing.T) {
	for range 20 {
		code, err := generateUserCode()
		if err != nil {
			t.Fatalf("generateUserCode: %v", err)
		}
		if len(code) != 9 || code[4] != '-' {
			t.Errorf("code = %q, want XXXX-XXXX format", code)
		}
		for _, c := range strings.ReplaceAll(code, "-", "") {
			if c == '0' || c == 'O' || c == '1' || c == 'I' || c == 'L' {
				t.Errorf("code %q contains ambiguous char %q", code, c)
			}
		}
	}
}

func TestSha256HashDeterministic(t *testing.T) {
	h1 := sha256Hash("test-input")
	h2 := sha256Hash("test-input")
	if h1 != h2 {
		t.Error("sha256Hash should be deterministic")
	}
	if len(h1) != 64 {
		t.Errorf("hash length = %d, want 64", len(h1))
	}
	h3 := sha256Hash("different")
	if h1 == h3 {
		t.Error("different inputs should produce different hashes")
	}
}
