package api

import (
	"context"
	"log/slog"
	"time"

	providerapi "github.com/eigeninference/d-inference/coordinator/api/provider"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// BeginNativePair is an explicit in-process coordinator selection hook. There
// is deliberately no provider request or public HTTP route that can choose a
// peer, approve a runtime, or manufacture this authorization. The pair
// selector (StartClusterPairFormation) is its production counterpart: it
// offers Reserve two same-account members after matching what they registered.
func (s *Server) BeginNativePair(members [2]*registry.Provider, approvalID string, lifetime time.Duration) (*registry.NativePairSession, error) {
	if s.nativePairs == nil {
		return nil, registry.ErrNativePairApproval
	}
	connections, e := s.nativePairs.Connections(members)
	if e != nil {
		return nil, e
	}
	return s.nativePairs.Reserve(connections, approvalID, lifetime)
}

// StartClusterPairFormation runs the pair selector until ctx ends. It starts
// nothing unless the operator configured ClusterPairs; a catalog supplied
// directly keeps selection with the explicit BeginNativePair hook.
func (s *Server) StartClusterPairFormation(ctx context.Context) {
	if s.nativePairs == nil || !s.clusterPairFormation {
		return
	}
	saferun.Go(s.logger, "cluster_pair_formation", func() { s.nativePairs.RunFormation(ctx) })
}

// ClusterPairs reports the clusters members registered and where each stands.
// It is empty when pair control is not configured.
func (s *Server) ClusterPairs() []registry.NativePairView { return s.nativePairs.Pairs() }

// clusterPairCatalog resolves the approval catalog: an explicit one wins, else
// the operator's file. Startup validation (ServerConfig.CheckClusterPairs) has
// already accepted that file, so a failure here means it changed underneath
// the process; pair control then stays off rather than run on a partial read.
func clusterPairCatalog(cfg ServerConfig, logger *slog.Logger) *registry.NativeRuntimeCatalog {
	if cfg.NativePairCatalog != nil || !cfg.ClusterPairs.Enabled() {
		return cfg.NativePairCatalog
	}
	catalog, err := cfg.ClusterPairs.LoadCatalog()
	if err != nil {
		logger.Error("cluster pair catalog unreadable; pair control stays disabled", "error", err)
		return nil
	}
	logger.Warn("EXPERIMENTAL cluster pair control enabled from the operator catalog",
		"catalog", cfg.ClusterPairs.CatalogPath, "trusted_tls_proxies", len(cfg.ClusterPairs.TrustedTLSProxies))
	return catalog
}

// clusterPairTrustedTLSProxies resolves the member transport policy. A list
// that does not parse trusts no proxy.
func clusterPairTrustedTLSProxies(cfg ServerConfig, logger *slog.Logger) providerapi.TrustedTLSProxies {
	trusted, err := providerapi.ParseTrustedTLSProxies(cfg.ClusterPairs.TrustedTLSProxies)
	if err != nil {
		logger.Error("cluster pair trusted TLS proxies rejected; no proxy is trusted", "error", err)
		return providerapi.TrustedTLSProxies{}
	}
	return trusted
}
