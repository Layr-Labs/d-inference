package inference

import "github.com/eigeninference/d-inference/coordinator/registry"

// missingAllowlistEntries returns the live artifact of each catalog model that
// the cache allowlist names only under superseded tuples. A catalog sync
// publishes every identity before its files are fetched, so this does not wait
// for readiness: the answer would otherwise flip on each sync.
func (s *Owner) missingAllowlistEntries() []registry.CacheRoutingArtifact {
	statuses := s.promptArtifacts.Statuses()
	live := make([]registry.CacheRoutingArtifact, 0, len(statuses))
	for _, status := range statuses {
		live = append(live, registry.CacheRoutingArtifact{
			ModelID:              status.ModelID,
			ModelAggregateSHA256: status.ModelAggregateSHA256,
			PromptContractID:     status.PromptContractID,
		})
	}
	return s.registry.MissingCacheRoutingAllowlistEntries(live)
}

// warnNewlyMissingAllowlistEntries logs each missing entry once for as long as
// it stays missing; one that is appended and later missing again warns again.
// The public status carries only the count, so the operator log is where the
// exact tuple to append is named.
func (s *Owner) warnNewlyMissingAllowlistEntries(missing []registry.CacheRoutingArtifact) {
	s.staleAllowlistMu.Lock()
	defer s.staleAllowlistMu.Unlock()
	current := make(map[registry.CacheRoutingArtifact]struct{}, len(missing))
	for _, artifact := range missing {
		current[artifact] = struct{}{}
		if _, warned := s.staleAllowlistWarned[artifact]; warned {
			continue
		}
		s.logger.Warn("cache routing allowlist names this model under another artifact; its requests skip cache routing until this tuple is appended",
			"model_id", artifact.ModelID,
			"model_aggregate_sha256", artifact.ModelAggregateSHA256,
			"prompt_contract_id", artifact.PromptContractID)
	}
	s.staleAllowlistWarned = current
}
