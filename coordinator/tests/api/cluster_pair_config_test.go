package api_test

// The cluster pair opt-in is validated before startup: a mistyped catalog file
// or proxy address stops the coordinator instead of silently disabling the
// feature or trusting a different set of peers.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	providerapi "github.com/eigeninference/d-inference/coordinator/api/provider"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/clustermember"
)

func TestClusterPairConfigCheck(t *testing.T) {
	valid := clustermember.CatalogFile(t, clustermember.Approval(pairApproval, pairModel, pairChip))
	garbage := filepath.Join(t.TempDir(), "garbage.json")
	if err := os.WriteFile(garbage, []byte(`{"schema":"darkbloom_cluster_pair_catalog_v1","approvals":[{"id":"x"}]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name    string
		config  api.ClusterPairConfig
		wantErr string
	}{
		{name: "disabled by default"},
		{name: "catalog only", config: api.ClusterPairConfig{CatalogPath: valid}},
		{name: "catalog and proxy", config: api.ClusterPairConfig{CatalogPath: valid, TrustedTLSProxies: []string{"127.0.0.1/32", "::1"}}},
		{name: "proxy without catalog", config: api.ClusterPairConfig{TrustedTLSProxies: []string{"127.0.0.1"}},
			wantErr: "requires EIGENINFERENCE_CLUSTER_PAIR_CATALOG"},
		{name: "relative catalog path", config: api.ClusterPairConfig{CatalogPath: "catalog.json"}, wantErr: "must be absolute"},
		{name: "missing catalog file", config: api.ClusterPairConfig{CatalogPath: filepath.Join(t.TempDir(), "absent.json")},
			wantErr: "EIGENINFERENCE_CLUSTER_PAIR_CATALOG"},
		{name: "incomplete approval", config: api.ClusterPairConfig{CatalogPath: garbage}, wantErr: "approval 0"},
		{name: "proxy hostname", config: api.ClusterPairConfig{CatalogPath: valid, TrustedTLSProxies: []string{"caddy.internal"}},
			wantErr: "not an IP address or CIDR prefix"},
		{name: "proxy trusts everyone", config: api.ClusterPairConfig{CatalogPath: valid, TrustedTLSProxies: []string{"0.0.0.0/0"}},
			wantErr: "would trust every peer"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := api.ServerConfig{ClusterPairs: c.config}.CheckClusterPairs()
			switch {
			case c.wantErr == "" && err != nil:
				t.Fatalf("valid configuration rejected: %v", err)
			case c.wantErr != "" && (err == nil || !strings.Contains(err.Error(), c.wantErr)):
				t.Fatalf("error = %v, want one containing %q", err, c.wantErr)
			}
		})
	}
}

func TestTrustedTLSProxiesParsesAddressesAndPrefixes(t *testing.T) {
	if _, err := providerapi.ParseTrustedTLSProxies([]string{" 127.0.0.1 ", "", "fd00::/8", "192.168.1.0/24"}); err != nil {
		t.Fatalf("valid list rejected: %v", err)
	}
	for _, bad := range []string{"localhost", "127.0.0.1:8080", "::/0", "300.1.1.1", "10.0.0.0/33"} {
		if _, err := providerapi.ParseTrustedTLSProxies([]string{bad}); err == nil {
			t.Fatalf("%q accepted as a trusted proxy", bad)
		}
	}
}
