package inference

import "github.com/eigeninference/d-inference/coordinator/promptcontract"

func (s *Owner) cachePreloadSelection(verified []promptcontract.VerifiedPreloadArtifact, refreshAvailability bool) ([]promptcontract.PreloadDemandIdentity, []string) {
	admissible := s.registry.CachePreloadIdentities(verified)
	if !refreshAvailability || len(admissible) == 0 {
		return admissible, nil
	}
	public := make(map[string]bool)
	for _, model := range s.registry.ListModels() {
		public[model.ID] = true
	}
	var available []string
	for _, artifact := range verified {
		if public[artifact.ModelID] {
			available = append(available, artifact.ModelID)
		}
	}
	return admissible, available
}
