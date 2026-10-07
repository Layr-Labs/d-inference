package registry

// CandidateBinding is the immutable session/model identity captured by routing.
// Equality includes the exact provider session, not just its reusable ID.
// No live provider state is exposed by a retained binding.
type CandidateBinding struct {
	provider *Provider
	model    string
}

func BindCandidate(provider *Provider, model string) CandidateBinding {
	return CandidateBinding{provider: provider, model: model}
}
