package config_test

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/config"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/clustermember"
)

// The cluster pair opt-in is two environment variables. Unset, the
// configuration is the zero value and startup validation is unaffected; set
// wrongly, startup stops with a cluster_pairs error.
func TestClusterPairOptInIsReadFromTheEnvironmentAndChecked(t *testing.T) {
	t.Setenv(config.EnvPrefix+"_DATABASE_URL", "")
	t.Setenv(config.EnvPrefix+"_ALLOW_MEMORY_STORE", "true")
	t.Setenv(config.EnvPrefix+"_CLUSTER_PAIR_CATALOG", "")
	t.Setenv(config.EnvPrefix+"_CLUSTER_PAIR_TRUSTED_TLS_PROXIES", "")

	off := config.ReadAppConfig()
	if off.ServerConfig.ClusterPairs.Enabled() || off.ServerConfig.ClusterPairs.CatalogPath != "" ||
		len(off.ServerConfig.ClusterPairs.TrustedTLSProxies) != 0 || off.ServerConfig.NativePairCatalog != nil {
		t.Fatalf("cluster pairs are not off by default: %+v", off.ServerConfig.ClusterPairs)
	}
	if err := off.Check(); err != nil {
		t.Fatalf("default configuration rejected: %v", err)
	}

	catalog := clustermember.CatalogFile(t, clustermember.Approval("approval", "model", "Apple M3 Max"))
	t.Setenv(config.EnvPrefix+"_CLUSTER_PAIR_CATALOG", catalog)
	t.Setenv(config.EnvPrefix+"_CLUSTER_PAIR_TRUSTED_TLS_PROXIES", "127.0.0.1/32, ::1")
	on := config.ReadAppConfig()
	if got := on.ServerConfig.ClusterPairs; got.CatalogPath != catalog || len(got.TrustedTLSProxies) != 2 ||
		got.TrustedTLSProxies[0] != "127.0.0.1/32" || got.TrustedTLSProxies[1] != "::1" {
		t.Fatalf("cluster pair opt-in not read from the environment: %+v", got)
	}
	if err := on.Check(); err != nil {
		t.Fatalf("valid opt-in rejected: %v", err)
	}

	t.Setenv(config.EnvPrefix+"_CLUSTER_PAIR_CATALOG", filepath.Join(t.TempDir(), "absent.json"))
	if err := config.ReadAppConfig().Check(); err == nil || !strings.HasPrefix(err.Error(), "cluster_pairs: ") {
		t.Fatalf("Check with a missing catalog file = %v, want a cluster_pairs error", err)
	}
	t.Setenv(config.EnvPrefix+"_CLUSTER_PAIR_CATALOG", catalog)
	t.Setenv(config.EnvPrefix+"_CLUSTER_PAIR_TRUSTED_TLS_PROXIES", "caddy")
	if err := config.ReadAppConfig().Check(); err == nil || !strings.HasPrefix(err.Error(), "cluster_pairs: ") {
		t.Fatalf("Check with a proxy hostname = %v, want a cluster_pairs error", err)
	}
}
