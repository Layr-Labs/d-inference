package config_test

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/config"
)

func TestReadAppConfigRequiresDurableStoreUnlessMemoryAllowed(t *testing.T) {
	t.Setenv(config.EnvPrefix+"_DATABASE_URL", "")
	t.Setenv(config.EnvPrefix+"_ALLOW_MEMORY_STORE", "")
	t.Setenv(config.EnvPrefix+"_ADMIN_KEY", "config-test-admin-key")
	t.Setenv(config.EnvPrefix+"_ADMIN_EMAILS", "a@example.test, b@example.test")
	t.Setenv(config.EnvPrefix+"_RELEASE_KEY", "config-test-release-key")

	cfg := config.ReadAppConfig()
	if cfg.AdminKey != "config-test-admin-key" || cfg.ReleaseKey != "config-test-release-key" {
		t.Fatalf("keys not read from the environment: admin=%q release=%q", cfg.AdminKey, cfg.ReleaseKey)
	}
	if len(cfg.AdminEmails) != 2 || cfg.AdminEmails[0] != "a@example.test" || cfg.AdminEmails[1] != "b@example.test" {
		t.Fatalf("admin emails = %q", cfg.AdminEmails)
	}
	err := cfg.Check()
	if err == nil || !strings.HasPrefix(err.Error(), "store: ") {
		t.Fatalf("Check without a database or memory opt-in = %v, want a store error", err)
	}

	t.Setenv(config.EnvPrefix+"_ALLOW_MEMORY_STORE", "true")
	if err := config.ReadAppConfig().Check(); err != nil {
		t.Fatalf("Check with the memory store allowed = %v, want nil", err)
	}
}
