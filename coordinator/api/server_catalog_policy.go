package api

import (
	"log/slog"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// SyncModelCatalog reads active models from the store and updates the
// registry's model catalog. Call this at startup and after admin catalog changes.
func (s *Server) SyncModelCatalog() {
	registryRows, err := s.store.ListActiveModelRegistryWithError()
	if err != nil {
		s.logger.Error("model registry catalog sync failed", "error", err)
		return
	}
	entries := make([]registry.CatalogEntry, 0, len(registryRows))
	for _, row := range registryRows {
		if row.ActiveVersion == nil {
			continue
		}
		entries = append(entries, registry.CatalogEntry{
			ID:         row.ID,
			WeightHash: row.ActiveVersion.AggregateSHA256,
			SizeGB:     float64(row.ActiveVersion.TotalSizeBytes) / 1e9,
			MinRAMGB:   row.MinRAMGB,
		})
	}
	s.registry.SetModelCatalog(entries)
	s.logger.Info("model registry catalog synced to registry", "active_models", len(entries))

	s.syncModelAliases()
	s.invalidateCatalogCache()
}

// syncModelAliases loads public-alias → {desired, previous} build pointers from
// the store into the registry so consumer requests for an alias (e.g.
// "gemma-4-26b") resolve to a concrete build. Only active aliases with a
// non-empty desired build are installed.
func (s *Server) syncModelAliases() {
	aliases, err := s.store.ListModelAliases()
	if err != nil {
		s.logger.Error("model alias sync failed", "error", err)
		return
	}
	resolved := make(map[string]registry.AliasTarget, len(aliases))
	for _, a := range aliases {
		if !a.Active || a.DesiredBuild == "" {
			continue
		}
		resolved[a.AliasID] = registry.AliasTarget{
			Desired:  a.DesiredBuild,
			Previous: a.PreviousBuild,
			Retired:  a.RetiredBuilds,
		}
	}
	s.registry.SetModelAliases(resolved)
	s.logger.Info("model aliases synced to registry", "active_aliases", len(resolved))
}

// invalidateCatalogCache removes all cached model catalog responses so the
// next request picks up any changes made by admin endpoints.
func (s *Server) invalidateCatalogCache() {
	if s.readCache == nil {
		return
	}
	for _, typeFilter := range []string{"", "text"} {
		for _, includeAliases := range []bool{false, true} {
			s.readCache.Invalidate(modelCatalogCacheKey(typeFilter, includeAliases))
		}
	}
}

// SetKnownBinaryHashes configures the set of accepted provider binary hashes.
// SetBinaryHashEnforcement toggles whether a self-reported binaryHash mismatch
// deroutes a provider. Default false (v0.6.0): binaryHash is demoted to drift
// telemetry; APNs code-identity attestation is the real signal. Enable only for
// rollback or to test the legacy enforcement path.
// SetTTFTHardReject toggles the per-request TTFT admission ceiling between a
// hard 429 (true, legacy) and a soft routing preference (false, default). See
// the ttftHardReject field for rationale. Call before serving starts.
func (s *Server) SetTTFTHardReject(enabled bool) {
	s.ttftHardReject = enabled
}

func (s *Server) SetBinaryHashEnforcement(enabled bool) {
	s.binaryHashEnforce = enabled
}

// Providers whose binary SHA-256 doesn't match any known hash are rejected.
func (s *Server) SetKnownBinaryHashes(hashes []string) {
	normalized := normalizeKnownBinaryHashes(hashes, s.logger)

	s.binaryHashPolicyMu.Lock()
	defer s.binaryHashPolicyMu.Unlock()

	s.manualKnownBinaryHashes = normalized
	s.manualBinaryHashPolicyConfigured = hasConfiguredHashInput(hashes)
	s.rebuildBinaryHashPolicyLocked()
}

func normalizeKnownBinaryHashes(hashes []string, logger *slog.Logger) map[string]bool {
	normalizedHashes := make(map[string]bool, len(hashes))
	for _, h := range hashes {
		normalized, err := normalizeSHA256Hex(h, "known_binary_hashes")
		if err != nil {
			if strings.TrimSpace(h) != "" {
				logger.Warn("invalid known binary hash ignored", "hash", h, "error", err)
			}
			continue
		}
		normalizedHashes[normalized] = true
	}
	return normalizedHashes
}

// AddKnownBinaryHashes adds hashes to the existing known set (for env var fallback).
func (s *Server) AddKnownBinaryHashes(hashes []string) {
	normalized := normalizeKnownBinaryHashes(hashes, s.logger)

	s.binaryHashPolicyMu.Lock()
	defer s.binaryHashPolicyMu.Unlock()

	if s.manualKnownBinaryHashes == nil {
		s.manualKnownBinaryHashes = make(map[string]bool)
	}
	if hasConfiguredHashInput(hashes) {
		s.manualBinaryHashPolicyConfigured = true
	}
	for h := range normalized {
		s.manualKnownBinaryHashes[h] = true
	}
	s.rebuildBinaryHashPolicyLocked()
}

func hasConfiguredHashInput(hashes []string) bool {
	for _, h := range hashes {
		if strings.TrimSpace(h) != "" {
			return true
		}
	}
	return false
}

// SetConsoleURL sets the frontend URL for device auth verification links.
func (s *Server) SetConsoleURL(url string) {
	s.consoleURL = url
}

// SetCORSOrigin configures the allowed CORS origin.
func (s *Server) SetCORSOrigin(origin string) {
	s.corsOrigin = origin
}

// SetReleaseKey configures the scoped release key for GitHub Actions.
func (s *Server) SetReleaseKey(key string) {
	s.releaseKey = key
}

// SetCoordinatorKey installs the X25519 keypair the coordinator publishes
// for sender-to-coordinator request encryption. Pass nil to disable.
func (s *Server) SetCoordinatorKey(k *e2e.CoordinatorKey) {
	s.coordinatorKey = k
}

// CoordinatorKey returns the configured coordinator encryption key (or nil).
// Exposed for tests; production code should not need this.
func (s *Server) CoordinatorKey() *e2e.CoordinatorKey {
	return s.coordinatorKey
}

// SyncBinaryHashes rebuilds knownBinaryHashes from all active releases.
// Called at startup and after release changes.
func (s *Server) SyncBinaryHashes() {
	releases := s.store.ListReleases()
	hashes := make(map[string]bool)
	policyConfigured := false
	for _, r := range releases {
		if !r.Active {
			continue
		}
		policyConfigured = true
		normalized, err := normalizeSHA256Hex(r.BinaryHash, "release.binary_hash")
		if err != nil {
			s.logger.Warn("invalid release binary hash ignored",
				"version", r.Version,
				"platform", r.Platform,
				"error", err,
			)
			continue
		}
		hashes[normalized] = true
	}

	s.binaryHashPolicyMu.Lock()
	s.releaseKnownBinaryHashes = hashes
	s.releaseBinaryHashPolicyConfigured = policyConfigured
	s.rebuildBinaryHashPolicyLocked()
	knownHashCount := len(s.knownBinaryHashes)
	effectivePolicyConfigured := s.binaryHashPolicyConfigured
	s.binaryHashPolicyMu.Unlock()

	s.logger.Info("binary hashes synced from releases", "known_hashes", knownHashCount, "policy_configured", effectivePolicyConfigured)
}

func (s *Server) rebuildBinaryHashPolicyLocked() {
	hashes := make(map[string]bool, len(s.manualKnownBinaryHashes)+len(s.releaseKnownBinaryHashes))
	for h := range s.releaseKnownBinaryHashes {
		hashes[h] = true
	}
	for h := range s.manualKnownBinaryHashes {
		hashes[h] = true
	}
	s.knownBinaryHashes = hashes
	s.binaryHashPolicyConfigured = s.manualBinaryHashPolicyConfigured || s.releaseBinaryHashPolicyConfigured
}

func (s *Server) binaryHashPolicySnapshot() (bool, map[string]bool) {
	s.binaryHashPolicyMu.RLock()
	defer s.binaryHashPolicyMu.RUnlock()

	return s.binaryHashPolicyConfigured, s.knownBinaryHashes
}

// SetMinDecodeTPS sets the per-request sustained-decode floor (tokens/sec) the
// scheduler uses as a soft routing preference. <= 0 disables it. See the
// minDecodeTPS field. Call before serving starts.
func (s *Server) SetMinDecodeTPS(tps float64) {
	if tps < 0 {
		tps = 0
	}
	s.minDecodeTPS = tps
}
