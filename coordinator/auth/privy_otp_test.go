package auth

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

type otpRoundTripper func(*http.Request) (*http.Response, error)

func (f otpRoundTripper) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestEmailOTPJSONPreservesUntrustedStrings(t *testing.T) {
	for _, input := range []struct{ name, email, code string }{
		{"ordinary", "user@example.com", "123456"},
		{"empty fields", "", ""},
		{"quoted address", `"quoted.local"@example.com`, "123456"},
		{"escape sequences", "name\\part\n@example.com", "12\t34\\56"},
		{"attempted extra field", `user@example.com","admin":true,"extra":"`, `123","email":"other@example.com`},
	} {
		for _, verify := range []bool{false, true} {
			t.Run(input.name+map[bool]string{false: "/init", true: "/verify"}[verify], func(t *testing.T) {
				_, pem := genES256Key(t)
				a := newAuth(t, pem, "test-secret", testMemStore())
				called := false
				a.httpClient.Transport = otpRoundTripper(func(r *http.Request) (*http.Response, error) {
					called = true
					if r.Method != http.MethodPost || r.URL.Host != "auth.privy.io" || r.Header.Get("Content-Type") != "application/json" {
						t.Fatalf("unexpected OTP request: %s %s %v", r.Method, r.URL, r.Header)
					}
					id, secret, ok := r.BasicAuth()
					if !ok || id != testAppID || secret != "test-secret" || r.Header.Get("Privy-App-Id") != testAppID {
						t.Fatal("OTP authentication headers changed")
					}
					body, err := io.ReadAll(r.Body)
					if err != nil {
						t.Fatal(err)
					}
					if input.name == "ordinary" {
						want := `{"email":"user@example.com"}`
						if verify {
							want = `{"email":"user@example.com","code":"123456"}`
						}
						if string(body) != want {
							t.Fatalf("ordinary OTP wire bytes changed: %q", body)
						}
					}
					var got map[string]string
					if err := json.Unmarshal(body, &got); err != nil {
						t.Fatalf("OTP payload is not a string-valued JSON object: %q: %v", body, err)
					}
					wantFields, path := 1, "/api/v1/auth/email/init"
					if verify {
						wantFields, path = 2, "/api/v1/auth/email/authenticate"
						if got["code"] != input.code {
							t.Fatalf("code was rewritten: %q", got["code"])
						}
					}
					if len(got) != wantFields || got["email"] != input.email || r.URL.Path != path {
						t.Fatalf("OTP request changed fields or operation: %s %q", r.URL.Path, body)
					}
					return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"token":"access-token"}`)), Header: make(http.Header)}, nil
				})
				if verify {
					token, err := a.VerifyEmailOTP(input.email, input.code)
					if err != nil || token != "access-token" {
						t.Fatalf("verify: token=%q error=%v", token, err)
					}
				} else if err := a.InitEmailOTP(input.email); err != nil {
					t.Fatal(err)
				}
				if !called {
					t.Fatal("OTP transport was not called")
				}
			})
		}
	}
}
