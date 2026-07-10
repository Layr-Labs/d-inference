package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestCommittedContractsAreCurrent(t *testing.T) {
	root, err := repositoryRoot("")
	if err != nil {
		t.Fatal(err)
	}
	generators := []func(string) (map[string][]byte, error){
		generateRoutes,
		generateProtocol,
		generateHTTP,
		generateCrypto,
		generateRouting,
	}
	for _, generate := range generators {
		outputs, err := generate(root)
		if err != nil {
			t.Fatal(err)
		}
		for relative, generated := range outputs {
			generated = ensureTrailingNewline(generated)
			committed, err := os.ReadFile(filepath.Join(root, relative))
			if err != nil {
				t.Fatalf("read %s: %v", relative, err)
			}
			if !bytes.Equal(committed, generated) {
				t.Errorf("%s is stale; run `make contracts-update`", relative)
			}
		}
	}
}

func TestRouteAuthClassification(t *testing.T) {
	tests := []struct {
		path    string
		handler string
		want    string
	}{
		{"/v1/admin/auth/init", "handleAdminAuthInit", "public"},
		{"/v1/admin/models/register", "handleRegisterModel", "publishing_key_or_admin_key"},
		{"/v1/admin/state-export", "handleAdminStateExport", "admin_key_only"},
		{"/v1/admin/routes", "handleAdminRoutes", "admin_key_only"},
		{"/v1/admin/drain", "requireAuth(handleAdminDrain)", "admin_key_or_privy_admin"},
		{"/v1/keys", "requirePrivyAuth(handleListAPIKeys)", "privy_jwt"},
		{"/v1/models", "requireAuth(handleListModels)", "api_key_or_privy"},
		{"/v1/billing/stripe/webhook", "handleStripeWebhook", "stripe_signature"},
		{"/v1/telemetry/events", "handleTelemetryIngest", "optional_provider_token_privy_api_key_or_anonymous"},
	}
	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			if got := routeAuth(test.path, test.handler); got != test.want {
				t.Fatalf("routeAuth(%q) = %q, want %q", test.path, got, test.want)
			}
		})
	}
}
