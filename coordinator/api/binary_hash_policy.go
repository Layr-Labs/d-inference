package api

import (
	"log/slog"
	"strings"
)

// SetKnownBinaryHashes configures the set of accepted provider binary hashes.
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
