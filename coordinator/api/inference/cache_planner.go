package inference

import "github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"

// NewCachePlanner binds optional cache planning to this owner's registry,
// prompt resources and observation sinks.
func (s *Owner) NewCachePlanner() routeplan.CachePlanner {
	return routeplan.CachePlanner{Registry: s.registry, Artifacts: s.promptArtifacts,
		Contract: s.promptContract, Preloader: s.promptPreloader, Observation: s.observation}
}
