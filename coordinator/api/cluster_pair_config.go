package api

import (
	"fmt"
	"os"
	"path/filepath"

	providerapi "github.com/eigeninference/d-inference/coordinator/api/provider"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// ClusterPairConfig is the explicit opt-in for experimental two-Mac pair
// serving. The zero value keeps all of it off: no approval catalog, no pair
// selector, no member attachment, and a member registration is acknowledged
// exactly as it is without this feature.
type ClusterPairConfig struct {
	// CatalogPath is the operator's reviewed runtime approval file
	// (EIGENINFERENCE_CLUSTER_PAIR_CATALOG, registry.NativeRuntimeCatalogSchema).
	// Only this file can approve a native runtime; no provider message can.
	CatalogPath string
	// TrustedTLSProxies lists the addresses or CIDR prefixes of the operator's
	// TLS-terminating reverse proxy (EIGENINFERENCE_CLUSTER_PAIR_TRUSTED_TLS_PROXIES).
	// Empty keeps the rule that a member connection must itself be TLS. See
	// providerapi.TrustedTLSProxies for what a nonempty value assumes.
	TrustedTLSProxies []string
}

// Enabled reports whether pair control is configured at all.
func (c ClusterPairConfig) Enabled() bool { return c.CatalogPath != "" }

// Check validates the opt-in before startup so a mistyped file or address
// stops the coordinator instead of silently disabling or widening the feature.
func (c ClusterPairConfig) Check() error {
	if _, err := providerapi.ParseTrustedTLSProxies(c.TrustedTLSProxies); err != nil {
		return fmt.Errorf("EIGENINFERENCE_CLUSTER_PAIR_TRUSTED_TLS_PROXIES: %w", err)
	}
	if !c.Enabled() {
		if len(c.TrustedTLSProxies) != 0 {
			return fmt.Errorf("EIGENINFERENCE_CLUSTER_PAIR_TRUSTED_TLS_PROXIES requires EIGENINFERENCE_CLUSTER_PAIR_CATALOG")
		}
		return nil
	}
	if _, err := c.LoadCatalog(); err != nil {
		return fmt.Errorf("EIGENINFERENCE_CLUSTER_PAIR_CATALOG: %w", err)
	}
	return nil
}

// LoadCatalog reads the approval file. A disabled configuration has none.
func (c ClusterPairConfig) LoadCatalog() (*registry.NativeRuntimeCatalog, error) {
	if !c.Enabled() {
		return nil, nil
	}
	if !filepath.IsAbs(c.CatalogPath) {
		return nil, fmt.Errorf("path must be absolute")
	}
	data, err := os.ReadFile(c.CatalogPath)
	if err != nil {
		return nil, err
	}
	return registry.ParseNativeRuntimeCatalog(data)
}

// CheckClusterPairs validates the cluster pair opt-in before startup.
func (c ServerConfig) CheckClusterPairs() error { return c.ClusterPairs.Check() }
