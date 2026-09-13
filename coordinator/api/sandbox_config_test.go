package api

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/env"
)

func TestSandboxServiceConfigFailsClosed(t *testing.T) {
	for _, suffix := range []string{"SERVICE_ENABLED", "ADMISSION_ENABLED", "ALLOWED_ACCOUNT_IDS"} {
		t.Setenv(env.EnvPrefix+"_SANDBOX_"+suffix, "")
	}
	defaults := ReadServerConfig().SandboxService
	if defaults.Enabled || defaults.AdmissionEnabled || defaults.admits("account") {
		t.Fatalf("sandbox service unexpectedly enabled by default: %+v", defaults)
	}
	for name, config := range map[string]SandboxServiceConfig{
		"admission without service":  {AdmissionEnabled: true, AllowedAccountIDs: []string{"account"}},
		"admission without accounts": {Enabled: true, AdmissionEnabled: true},
		"wildcard":                   {AllowedAccountIDs: []string{"*"}},
		"empty account":              {AllowedAccountIDs: []string{""}},
		"duplicate account":          {AllowedAccountIDs: []string{"account", "account"}},
		"whitespace":                 {AllowedAccountIDs: []string{"account other"}},
	} {
		t.Run(name, func(t *testing.T) {
			if config.Check() == nil {
				t.Fatalf("invalid config accepted: %+v", config)
			}
		})
	}
	t.Setenv(env.EnvPrefix+"_SANDBOX_SERVICE_ENABLED", "true")
	t.Setenv(env.EnvPrefix+"_SANDBOX_ADMISSION_ENABLED", "true")
	t.Setenv(env.EnvPrefix+"_SANDBOX_ALLOWED_ACCOUNT_IDS", "account-one,account-two")
	configured := ReadServerConfig().SandboxService
	if err := configured.Check(); err != nil || !configured.admits("account-one") || configured.admits("other") {
		t.Fatalf("configured admission: %+v, error=%v", configured, err)
	}
}

func TestSandboxDisabledDoesNotStartControllerOrChangeInferenceRoutes(t *testing.T) {
	server := newSandboxHostTestServer(t, func(config *ServerConfig) {
		config.SandboxService = SandboxServiceConfig{}
	})
	if server.sandboxes != nil {
		t.Fatal("disabled sandbox service started a controller and sweeper")
	}
	for path, want := range map[string]int{
		"/v1/sandboxes":    http.StatusServiceUnavailable,
		"/ws/sandbox-host": http.StatusServiceUnavailable,
		"/v1/models":       http.StatusOK,
		"/health":          http.StatusOK,
	} {
		t.Run(path, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, path, nil)
			request.Header.Set("Authorization", "Bearer test-key")
			response := httptest.NewRecorder()
			server.Handler().ServeHTTP(response, request)
			if response.Code != want {
				t.Fatalf("status=%d want=%d body=%s", response.Code, want, response.Body.String())
			}
		})
	}
}

func TestSandboxAdmissionRequiresEnrolledAccount(t *testing.T) {
	for name, config := range map[string]SandboxServiceConfig{
		"paused":       {Enabled: true},
		"not enrolled": {Enabled: true, AdmissionEnabled: true, AllowedAccountIDs: []string{"another-account"}},
	} {
		t.Run(name, func(t *testing.T) {
			server := newSandboxHostTestServer(t, func(serverConfig *ServerConfig) {
				serverConfig.SandboxService = config
			})
			want := http.StatusForbidden
			if !config.AdmissionEnabled {
				want = http.StatusServiceUnavailable
			}
			for _, path := range []string{
				"/v1/sandboxes",
				"/v1/sandboxes/10000000-0000-0000-0000-000000000001/commands",
				"/v1/sandboxes/10000000-0000-0000-0000-000000000001/renew",
			} {
				request := httptest.NewRequest(http.MethodPost, path, nil)
				request.Header.Set("Authorization", "Bearer test-key")
				response := httptest.NewRecorder()
				server.Handler().ServeHTTP(response, request)
				if response.Code != want {
					t.Fatalf("%s status=%d want=%d body=%s", path, response.Code, want, response.Body.String())
				}
			}
		})
	}
}
