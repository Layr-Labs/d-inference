package inference

import (
	"github.com/eigeninference/d-inference/coordinator/internal/inference/cold"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Owner) queueBeforeShedEnabled() bool {
	return cold.New(nil, nil).QueueBeforeShedEnabled()
}

func (s *Owner) coldDispatchEnabled() bool {
	return cold.New(nil, nil).Enabled()
}

func (s *Owner) coldSpillAvailable(model string, traits registry.RequestTraits, requiresVision bool, allowedSerials []string) bool {
	if s == nil {
		return false
	}
	return cold.New(s.registry, s.logger).SpillAvailable(model, traits, requiresVision, allowedSerials)
}

func (s *Owner) kickColdDispatch(model string) {
	if s == nil {
		return
	}
	cold.New(s.registry, s.logger).Kick(model)
}
