package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/ratelimit"
)

func TestProviderWaitlistSignupPersistsOtherMachine(t *testing.T) {
	srv, st := testServer(t)
	srv.SetProviderWaitlistRateLimiter(ratelimit.New(ratelimit.Config{RPS: 100, Burst: 100}))

	response := postProviderWaitlist(t, srv, map[string]any{
		"email":         " Owner@Example.com ",
		"chip":          "other",
		"memory_gb":     64,
		"gpu_cores":     40,
		"other_machine": " M6 developer kit ",
		"consent":       true,
		"company":       "",
	}, "192.0.2.10:1234")

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", response.Code, response.Body.String())
	}
	if got := response.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control = %q, want no-store", got)
	}
	if got := response.Header().Get("Access-Control-Allow-Origin"); got != "*" {
		t.Fatalf("Access-Control-Allow-Origin = %q, want wildcard", got)
	}
	signups, err := st.ListProviderWaitlistSignups(context.Background(), 10)
	if err != nil {
		t.Fatalf("list signups: %v", err)
	}
	if len(signups) != 1 {
		t.Fatalf("signup count = %d, want 1", len(signups))
	}
	got := signups[0]
	if got.Email != "owner@example.com" || got.Chip != "other" ||
		got.MemoryGB != 64 || got.GPUCores != 40 ||
		got.OtherMachine != "M6 developer kit" {
		t.Fatalf("persisted signup = %#v", got)
	}
	if strings.Contains(response.Body.String(), got.Email) {
		t.Fatal("response exposed submitted email")
	}
}

func TestProviderWaitlistCORSPreflightAllowsPublicPost(t *testing.T) {
	srv, _ := testServer(t)
	request := httptest.NewRequest(
		http.MethodOptions, "/v1/provider-waitlist", nil)
	request.Header.Set("Origin", "http://127.0.0.1:3000")
	request.Header.Set("Access-Control-Request-Method", http.MethodPost)
	response := httptest.NewRecorder()

	srv.Handler().ServeHTTP(response, request)

	if response.Code != http.StatusNoContent {
		t.Fatalf("preflight status = %d", response.Code)
	}
	if got := response.Header().Get("Access-Control-Allow-Origin"); got != "*" {
		t.Fatalf("Access-Control-Allow-Origin = %q, want wildcard", got)
	}
	if got := response.Header().Get("Access-Control-Allow-Methods"); !strings.Contains(got, http.MethodPost) {
		t.Fatalf("Access-Control-Allow-Methods = %q, want POST", got)
	}
}

func TestProviderWaitlistSignupUpsertsEmail(t *testing.T) {
	srv, st := testServer(t)
	srv.SetProviderWaitlistRateLimiter(ratelimit.New(ratelimit.Config{RPS: 100, Burst: 100}))

	for _, payload := range []map[string]any{
		{
			"email": "owner@example.com", "chip": "M2", "memory_gb": 24,
			"other_machine": "", "consent": true, "company": "",
		},
		{
			"email": "OWNER@example.com", "chip": "M4 Max (16-core CPU)", "memory_gb": 128,
			"other_machine": "discarded", "consent": true, "company": "",
		},
	} {
		response := postProviderWaitlist(t, srv, payload, "192.0.2.11:1234")
		if response.Code != http.StatusOK {
			t.Fatalf("status = %d: %s", response.Code, response.Body.String())
		}
	}

	signups, err := st.ListProviderWaitlistSignups(context.Background(), 10)
	if err != nil {
		t.Fatalf("list signups: %v", err)
	}
	if len(signups) != 1 {
		t.Fatalf("signup count = %d, want 1", len(signups))
	}
	if signups[0].Chip != "M4 Max" || signups[0].MemoryGB != 128 ||
		signups[0].OtherMachine != "" {
		t.Fatalf("updated signup = %#v", signups[0])
	}
}

func TestProviderWaitlistAcceptsEveryFutureCalculatorChip(t *testing.T) {
	for _, chip := range []string{"M5 Ultra", "M6"} {
		t.Run(chip, func(t *testing.T) {
			signup, err := validateProviderWaitlistSignup(
				providerWaitlistSignupRequest{
					Email: "owner@example.com", Chip: chip,
					MemoryGB: 32, Consent: true,
				})
			if err != nil {
				t.Fatalf("validate %q: %v", chip, err)
			}
			if signup.Chip != chip {
				t.Fatalf("chip = %q, want %q", signup.Chip, chip)
			}
		})
	}
}

func TestProviderWaitlistSignupValidation(t *testing.T) {
	tests := []struct {
		name    string
		payload map[string]any
	}{
		{
			name: "invalid email",
			payload: map[string]any{
				"email": "not-an-email", "chip": "M4", "memory_gb": 32,
				"other_machine": "", "consent": true, "company": "",
			},
		},
		{
			name: "consent required",
			payload: map[string]any{
				"email": "owner@example.com", "chip": "M4", "memory_gb": 32,
				"other_machine": "", "consent": false, "company": "",
			},
		},
		{
			name: "listed chip required",
			payload: map[string]any{
				"email": "owner@example.com", "chip": "Intel Xeon", "memory_gb": 32,
				"other_machine": "", "consent": true, "company": "",
			},
		},
		{
			name: "other text required",
			payload: map[string]any{
				"email": "owner@example.com", "chip": "other", "memory_gb": 32,
				"other_machine": " ", "consent": true, "company": "",
			},
		},
		{
			name: "memory bounded",
			payload: map[string]any{
				"email": "owner@example.com", "chip": "M4", "memory_gb": 2048,
				"other_machine": "", "consent": true, "company": "",
			},
		},
		{
			name: "GPU cores bounded",
			payload: map[string]any{
				"email": "owner@example.com", "chip": "M4 Max", "memory_gb": 64,
				"gpu_cores": 513, "other_machine": "", "consent": true, "company": "",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			srv, _ := testServer(t)
			srv.SetProviderWaitlistRateLimiter(
				ratelimit.New(ratelimit.Config{RPS: 100, Burst: 100}),
			)
			response := postProviderWaitlist(t, srv, test.payload, "192.0.2.12:1234")
			if response.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400: %s", response.Code, response.Body.String())
			}
		})
	}
}

func TestProviderWaitlistSignupRateLimitsBySourceIP(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetProviderWaitlistRateLimiter(
		ratelimit.New(ratelimit.Config{RPS: 0.02, Burst: 1}),
	)
	payload := map[string]any{
		"email": "owner@example.com", "chip": "M4", "memory_gb": 32,
		"other_machine": "", "consent": true, "company": "",
	}

	first := postProviderWaitlist(t, srv, payload, "192.0.2.13:1234")
	if first.Code != http.StatusOK {
		t.Fatalf("first status = %d: %s", first.Code, first.Body.String())
	}
	second := postProviderWaitlist(t, srv, payload, "192.0.2.13:5678")
	if second.Code != http.StatusTooManyRequests {
		t.Fatalf("second status = %d, want 429: %s", second.Code, second.Body.String())
	}
	if got := second.Header().Get("Retry-After"); got != "50" {
		t.Fatalf("Retry-After = %q, want rounded-up 50 seconds", got)
	}
	if got := second.Header().Get("Access-Control-Expose-Headers"); !strings.Contains(got, "Retry-After") {
		t.Fatalf("Access-Control-Expose-Headers = %q, want Retry-After", got)
	}

	otherIP := postProviderWaitlist(t, srv, payload, "192.0.2.14:1234")
	if otherIP.Code != http.StatusOK {
		t.Fatalf("other IP status = %d: %s", otherIP.Code, otherIP.Body.String())
	}
}

func TestProviderWaitlistSignupFailsClosedWithoutLimiter(t *testing.T) {
	srv, _ := testServer(t)
	response := postProviderWaitlist(t, srv, map[string]any{
		"email": "owner@example.com", "chip": "M4", "memory_gb": 32,
		"other_machine": "", "consent": true, "company": "",
	}, "192.0.2.15:1234")
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503: %s", response.Code, response.Body.String())
	}
}

func TestProviderWaitlistHoneypotDoesNotPersist(t *testing.T) {
	srv, st := testServer(t)
	srv.SetProviderWaitlistRateLimiter(ratelimit.New(ratelimit.Config{RPS: 100, Burst: 100}))
	response := postProviderWaitlist(t, srv, map[string]any{
		"email": "bot@example.com", "chip": "M4", "memory_gb": 32,
		"other_machine": "", "consent": true, "company": "spam",
	}, "192.0.2.16:1234")
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", response.Code, response.Body.String())
	}
	signups, err := st.ListProviderWaitlistSignups(context.Background(), 10)
	if err != nil {
		t.Fatalf("list signups: %v", err)
	}
	if len(signups) != 0 {
		t.Fatalf("honeypot persisted %d signups", len(signups))
	}
}

func TestAdminCanListProviderWaitlist(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetAdminKey("waitlist-admin")
	srv.SetProviderWaitlistRateLimiter(
		ratelimit.New(ratelimit.Config{RPS: 100, Burst: 100}))
	response := postProviderWaitlist(t, srv, map[string]any{
		"email": "owner@example.com", "chip": "M4", "memory_gb": 32,
		"other_machine": "", "consent": true, "company": "",
	}, "192.0.2.17:1234")
	if response.Code != http.StatusOK {
		t.Fatalf("signup status = %d: %s", response.Code, response.Body.String())
	}

	request := httptest.NewRequest(
		http.MethodGet, "/v1/admin/provider-waitlist?limit=10", nil)
	request.Header.Set("Authorization", "Bearer waitlist-admin")
	list := httptest.NewRecorder()
	srv.Handler().ServeHTTP(list, request)
	if list.Code != http.StatusOK {
		t.Fatalf("list status = %d: %s", list.Code, list.Body.String())
	}
	if !strings.Contains(list.Body.String(), "owner@example.com") {
		t.Fatalf("admin list missing signup: %s", list.Body.String())
	}
	if !strings.Contains(list.Body.String(), `"submitted_at"`) ||
		strings.Contains(list.Body.String(), `"consented_at"`) {
		t.Fatalf("admin list misrepresents unverified submission: %s",
			list.Body.String())
	}
	if list.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("cache control = %q", list.Header().Get("Cache-Control"))
	}
}

func postProviderWaitlist(
	t *testing.T,
	srv *Server,
	payload map[string]any,
	remoteAddr string,
) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}
	request := httptest.NewRequest(
		http.MethodPost,
		"/v1/provider-waitlist",
		bytes.NewReader(body),
	)
	request.RemoteAddr = remoteAddr
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	srv.Handler().ServeHTTP(response, request)
	return response
}
