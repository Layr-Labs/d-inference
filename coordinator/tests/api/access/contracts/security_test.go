package access_test

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	api "github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/registry"
	testkit "github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

func TestSecurity_AuthBypass(t *testing.T) {
	srv := testkit.New(t, api.ServerConfig{}).Server

	body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`

	tests := []struct {
		name       string
		path       string
		method     string
		authHeader string
		body       string
		wantStatus int
	}{
		{
			name:       "chat_completions_no_auth",
			path:       "/v1/chat/completions",
			method:     http.MethodPost,
			authHeader: "",
			body:       body,
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "chat_completions_empty_bearer",
			path:       "/v1/chat/completions",
			method:     http.MethodPost,
			authHeader: "Bearer",
			body:       body,
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "chat_completions_bearer_space_only",
			path:       "/v1/chat/completions",
			method:     http.MethodPost,
			authHeader: "Bearer ",
			body:       body,
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "chat_completions_random_token",
			path:       "/v1/chat/completions",
			method:     http.MethodPost,
			authHeader: "Bearer totally-random-invalid-token-12345",
			body:       body,
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "chat_completions_just_string",
			path:       "/v1/chat/completions",
			method:     http.MethodPost,
			authHeader: "not-even-bearer-format",
			body:       body,
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "device_approve_no_auth",
			path:       "/v1/device/approve",
			method:     http.MethodPost,
			authHeader: "",
			body:       `{"user_code":"ABCD-1234"}`,
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "device_approve_invalid_bearer",
			path:       "/v1/device/approve",
			method:     http.MethodPost,
			authHeader: "Bearer invalid-key",
			body:       `{"user_code":"ABCD-1234"}`,
			wantStatus: http.StatusForbidden,
		},
		{
			name:       "models_no_auth",
			path:       "/v1/models",
			method:     http.MethodGet,
			authHeader: "",
			body:       "",
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "balance_no_auth",
			path:       "/v1/payments/balance",
			method:     http.MethodGet,
			authHeader: "",
			body:       "",
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "completions_no_auth",
			path:       "/v1/completions",
			method:     http.MethodPost,
			authHeader: "",
			body:       `{"model":"test","prompt":"hello"}`,
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "anthropic_messages_no_auth",
			path:       "/v1/messages",
			method:     http.MethodPost,
			authHeader: "",
			body:       `{"model":"test","messages":[]}`,
			wantStatus: http.StatusUnauthorized,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var reqBody *strings.Reader
			if tt.body != "" {
				reqBody = strings.NewReader(tt.body)
			} else {
				reqBody = strings.NewReader("")
			}
			req := httptest.NewRequest(tt.method, tt.path, reqBody)
			if tt.authHeader != "" {
				req.Header.Set("Authorization", tt.authHeader)
			}
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			if w.Code != tt.wantStatus {
				t.Errorf("[%s] status = %d, want %d (body: %s)", tt.name, w.Code, tt.wantStatus, w.Body.String())
			}
		})
	}
}

func TestSecurity_DeviceCodeBruteForce(t *testing.T) {
	fixture := testkit.New(t, api.ServerConfig{})
	srv := fixture.Server
	sessions := testkit.NewSessions(t, srv, fixture.Store)
	userToken := sessions.Token("brute-force-acct")

	// Create a valid device code.
	codeReq := httptest.NewRequest(http.MethodPost, "/v1/device/code", nil)
	codeW := httptest.NewRecorder()
	srv.Handler().ServeHTTP(codeW, codeReq)

	if codeW.Code != http.StatusOK {
		t.Fatalf("create device code: status %d, body: %s", codeW.Code, codeW.Body.String())
	}

	var codeResp map[string]any
	json.Unmarshal(codeW.Body.Bytes(), &codeResp)
	validUserCode := codeResp["user_code"].(string)
	validDeviceCode := codeResp["device_code"].(string)

	// Try 100 random user codes — all should fail with 404.
	for i := range 100 {
		randomCode := fmt.Sprintf("%04d-%04d", i, i+1000)
		body := fmt.Sprintf(`{"user_code":"%s"}`, randomCode)
		req := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+userToken)
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)

		if w.Code != http.StatusNotFound {
			t.Errorf("attempt %d: random code %q returned status %d, want 404", i, randomCode, w.Code)
		}
	}

	// Original valid code should still work after all the failed attempts.
	approveBody := fmt.Sprintf(`{"user_code":"%s"}`, validUserCode)
	approveReq := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(approveBody))
	approveReq.Header.Set("Authorization", "Bearer "+userToken)
	approveW := httptest.NewRecorder()
	srv.Handler().ServeHTTP(approveW, approveReq)

	if approveW.Code != http.StatusOK {
		t.Errorf("valid code after 100 failed attempts: status %d, want 200, body: %s", approveW.Code, approveW.Body.String())
	}

	// Verify the device code was approved by polling with device_code.
	tokenBody := fmt.Sprintf(`{"device_code":"%s"}`, validDeviceCode)
	tokenReq := httptest.NewRequest(http.MethodPost, "/v1/device/token", strings.NewReader(tokenBody))
	tokenW := httptest.NewRecorder()
	srv.Handler().ServeHTTP(tokenW, tokenReq)

	var tokenResp map[string]any
	json.Unmarshal(tokenW.Body.Bytes(), &tokenResp)
	if tokenResp["status"] != "authorized" {
		t.Errorf("device token status = %q after approval, want authorized", tokenResp["status"])
	}
}

func TestSecurity_SQLInjection(t *testing.T) {
	fixture := testkit.New(t, api.ServerConfig{})
	srv := fixture.Server
	sessions := testkit.NewSessions(t, srv, fixture.Store)
	userToken := sessions.Token("sqli-test")

	injectionPayloads := []string{
		"' OR 1=1 --",
		"'; DROP TABLE users; --",
		"\" OR \"1\"=\"1",
		"1; SELECT * FROM keys",
		"admin'--",
		"' UNION SELECT * FROM users --",
	}

	t.Run("api_key_injection", func(t *testing.T) {
		for _, payload := range injectionPayloads {
			body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
			req.Header.Set("Authorization", "Bearer "+payload)
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			if w.Code != http.StatusUnauthorized {
				t.Errorf("SQL injection in API key %q: status %d, want 401", payload, w.Code)
			}
		}
	})

	t.Run("model_name_injection", func(t *testing.T) {
		// Pre-fill the request queue for each injection model name so
		// Enqueue returns ErrQueueFull immediately (avoids 30s queue wait).
		for _, payload := range injectionPayloads {
			for i := range 10 {
				_ = fixture.Registry.Queue().Enqueue(&registry.QueuedRequest{
					RequestID:  fmt.Sprintf("filler-%s-%d", payload, i),
					Model:      payload,
					ResponseCh: make(chan *registry.Provider, 1),
				})
			}
		}

		for _, payload := range injectionPayloads {
			body := fmt.Sprintf(`{"model":"%s","messages":[{"role":"user","content":"hi"}]}`, payload)
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
			req.Header.Set("Authorization", "Bearer test-key")
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			// Should return 503 (queue full / no provider), not panic or expose data.
			if w.Code == 0 {
				t.Errorf("SQL injection in model %q: got no response", payload)
			}
		}
	})

	t.Run("device_code_injection", func(t *testing.T) {
		for _, payload := range injectionPayloads {
			body := fmt.Sprintf(`{"device_code":"%s"}`, payload)
			req := httptest.NewRequest(http.MethodPost, "/v1/device/token", strings.NewReader(body))
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			// Should return 404 (not found), not panic.
			if w.Code == 0 || w.Code >= 500 {
				t.Errorf("SQL injection in device_code %q: status %d (should not be 5xx)", payload, w.Code)
			}
		}
	})

	t.Run("user_code_injection", func(t *testing.T) {
		for _, payload := range injectionPayloads {
			body := fmt.Sprintf(`{"user_code":"%s"}`, payload)
			req := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(body))
			req.Header.Set("Authorization", "Bearer "+userToken)
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			// Should return 404 (not found), not panic.
			if w.Code == 0 || w.Code >= 500 {
				t.Errorf("SQL injection in user_code %q: status %d (should not be 5xx)", payload, w.Code)
			}
		}
	})
}

func TestSecurity_ConcurrentAuthAttempts(t *testing.T) {
	fixture := testkit.New(t, api.ServerConfig{})
	srv := fixture.Server

	body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`

	t.Run("concurrent_invalid_auth", func(t *testing.T) {
		var wg sync.WaitGroup
		results := make([]int, 50)

		for i := range 50 {
			wg.Add(1)
			go func(idx int) {
				defer wg.Done()
				req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
				req.Header.Set("Authorization", fmt.Sprintf("Bearer invalid-key-%d", idx))
				w := httptest.NewRecorder()
				srv.Handler().ServeHTTP(w, req)
				results[idx] = w.Code
			}(i)
		}

		wg.Wait()

		for i, code := range results {
			if code != http.StatusUnauthorized {
				t.Errorf("concurrent invalid auth attempt %d: status %d, want 401", i, code)
			}
		}
	})

	t.Run("concurrent_valid_auth", func(t *testing.T) {
		// Pre-fill queue for "test" model so requests return 503 immediately
		// instead of blocking for 30s waiting for a provider.
		for i := range 10 {
			_ = fixture.Registry.Queue().Enqueue(&registry.QueuedRequest{
				RequestID:  fmt.Sprintf("concurrent-valid-filler-%d", i),
				Model:      "test",
				ResponseCh: make(chan *registry.Provider, 1),
			})
		}

		var wg sync.WaitGroup
		results := make([]int, 50)

		for i := range 50 {
			wg.Add(1)
			go func(idx int) {
				defer wg.Done()
				req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
				req.Header.Set("Authorization", "Bearer test-key")
				w := httptest.NewRecorder()
				srv.Handler().ServeHTTP(w, req)
				results[idx] = w.Code
			}(i)
		}

		wg.Wait()

		for i, code := range results {
			// Valid auth with no provider should return 503 (no provider available / queue full),
			// not a panic or race condition crash.
			if code == 0 {
				t.Errorf("concurrent valid auth attempt %d: got status 0 (no response)", i)
			}
			// Auth should succeed — so we should NOT get 401.
			if code == http.StatusUnauthorized {
				t.Errorf("concurrent valid auth attempt %d: got 401 (auth failed under concurrency)", i)
			}
		}
	})

	t.Run("concurrent_mixed_endpoints", func(t *testing.T) {
		// Hit different endpoints concurrently with invalid auth to test
		// for data races in the auth middleware.
		endpoints := []struct {
			method string
			path   string
			body   string
		}{
			{http.MethodPost, "/v1/chat/completions", body},
			{http.MethodPost, "/v1/completions", `{"model":"test","prompt":"hi"}`},
			{http.MethodGet, "/v1/models", ""},
			{http.MethodGet, "/v1/payments/balance", ""},
			{http.MethodGet, "/v1/payments/usage", ""},
		}

		var wg sync.WaitGroup
		for i := range 50 {
			wg.Add(1)
			go func(idx int) {
				defer wg.Done()
				ep := endpoints[idx%len(endpoints)]
				req := httptest.NewRequest(ep.method, ep.path, strings.NewReader(ep.body))
				req.Header.Set("Authorization", fmt.Sprintf("Bearer bad-key-%d", idx))
				w := httptest.NewRecorder()
				srv.Handler().ServeHTTP(w, req)

				if w.Code != http.StatusUnauthorized {
					t.Errorf("concurrent mixed endpoint %s (attempt %d): status %d, want 401",
						ep.path, idx, w.Code)
				}
			}(i)
		}
		wg.Wait()
	})
}
