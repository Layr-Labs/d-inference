package datadog

import (
	"log/slog"
	"os"
	"testing"
)

func TestConfigFromEnvDefaults(t *testing.T) {
	// Clear any DD env vars that might be set.
	for _, k := range []string{"DD_API_KEY", "DD_SITE", "DD_ENV", "DD_SERVICE", "DD_DOGSTATSD_URL"} {
		t.Setenv(k, "")
	}

	cfg := ConfigFromEnv()
	if cfg.Site != "datadoghq.com" {
		t.Errorf("Site: got %q want datadoghq.com", cfg.Site)
	}
	if cfg.Env != "production" {
		t.Errorf("Env: got %q want production", cfg.Env)
	}
	if cfg.Service != "d-inference-coordinator" {
		t.Errorf("Service: got %q want d-inference-coordinator", cfg.Service)
	}
	if cfg.StatsdAddr != "localhost:8125" {
		t.Errorf("StatsdAddr: got %q want localhost:8125", cfg.StatsdAddr)
	}
}

func TestConfigFromEnvOverrides(t *testing.T) {
	t.Setenv("DD_API_KEY", "test-key")
	t.Setenv("DD_SITE", "us5.datadoghq.com")
	t.Setenv("DD_ENV", "staging")
	t.Setenv("DD_SERVICE", "test-svc")
	t.Setenv("DD_DOGSTATSD_URL", "127.0.0.1:9999")

	cfg := ConfigFromEnv()
	if cfg.APIKey != "test-key" {
		t.Errorf("APIKey: got %q", cfg.APIKey)
	}
	if cfg.Site != "us5.datadoghq.com" {
		t.Errorf("Site: got %q", cfg.Site)
	}
	if cfg.Env != "staging" {
		t.Errorf("Env: got %q", cfg.Env)
	}
}

func TestForwardLogNilClient(t *testing.T) {
	// Should not panic.
	var c *Client
	c.ForwardLog(TelemetryLogEntry{
		Source:   "provider",
		Severity: "error",
		Kind:     "panic",
		Message:  "test",
	})
}

func TestForwardLogNoAPIKey(t *testing.T) {
	logger := slog.New(slog.NewJSONHandler(os.Stderr, nil))
	c := &Client{
		logger: logger,
		apiKey: "",
	}
	// Should be a no-op (no API key).
	c.ForwardLog(TelemetryLogEntry{
		Source:   "provider",
		Severity: "error",
		Kind:     "panic",
		Message:  "test",
	})
}

func TestMapSeverityToStatus(t *testing.T) {
	tests := []struct {
		in, want string
	}{
		{"debug", "debug"},
		{"info", "info"},
		{"warn", "warning"},
		{"error", "error"},
		{"fatal", "critical"},
		{"unknown", "info"},
	}
	for _, tt := range tests {
		got := mapSeverityToStatus(tt.in)
		if got != tt.want {
			t.Errorf("mapSeverityToStatus(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestTruncate(t *testing.T) {
	if truncate("abc", 5) != "abc" {
		t.Error("short string changed")
	}
	if truncate("abcdef", 3) != "abc..." {
		t.Error("long string not truncated")
	}
}
