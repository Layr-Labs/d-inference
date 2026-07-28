package main

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TestResolveDevInsecureProdGuards pins the defense-in-depth prod guards: a stray
// EIGENINFERENCE_DEV_INSECURE in a production-like deployment must fail CLOSED
// (refuse to start), never boot open.
func TestResolveDevInsecureProdGuards(t *testing.T) {
	cases := []struct {
		name            string
		databaseURL     string
		minTrust        string
		allowMemory     bool
		wantErrContains string // "" means expect success
		wantTrust       string // only checked on success
	}{
		{
			name:            "refuses against a durable database",
			databaseURL:     "postgres://prod/db",
			minTrust:        "",
			allowMemory:     true,
			wantErrContains: "DATABASE_URL",
		},
		{
			name:            "refuses contradictory MIN_TRUST=hardware",
			databaseURL:     "",
			minTrust:        string(registry.TrustHardware),
			allowMemory:     true,
			wantErrContains: "hardware",
		},
		{
			name:            "refuses without explicit memory-store opt-in (fail closed)",
			databaseURL:     "",
			minTrust:        "",
			allowMemory:     false,
			wantErrContains: "ALLOW_MEMORY_STORE",
		},
		{
			name:        "valid dev config defaults MIN_TRUST to none",
			databaseURL: "",
			minTrust:    "",
			allowMemory: true,
			wantTrust:   string(registry.TrustNone),
		},
		{
			name:        "valid dev config preserves an explicit non-hardware MIN_TRUST",
			databaseURL: "",
			minTrust:    string(registry.TrustSelfSigned),
			allowMemory: true,
			wantTrust:   string(registry.TrustSelfSigned),
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := resolveDevInsecure(tc.databaseURL, tc.minTrust, tc.allowMemory)
			if tc.wantErrContains != "" {
				if err == nil {
					t.Fatalf("expected refuse-to-start error containing %q, got nil (trust=%q)", tc.wantErrContains, got)
				}
				if !strings.Contains(err.Error(), tc.wantErrContains) {
					t.Fatalf("error %q does not contain %q", err.Error(), tc.wantErrContains)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.wantTrust {
				t.Fatalf("resolved trust = %q, want %q", got, tc.wantTrust)
			}
		})
	}
}
