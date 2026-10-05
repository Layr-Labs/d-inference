package observation

import "github.com/eigeninference/d-inference/coordinator/registry"

// finalizeAttemptProfile keeps flattening and sampling off the provider read loop.
func (s *Owner) finalizeAttemptProfile(rp *registry.RequestProfile, ap *registry.AttemptProfile) {
	if s != nil {
		s.profiler.Submit(rp, ap)
	}
}

func (s *Owner) RetainProviderProfile(ap *registry.AttemptProfile, raw []byte) {
	if s != nil {
		s.profiler.RetainProviderProfile(ap, raw)
	}
}
