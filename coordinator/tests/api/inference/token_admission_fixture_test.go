package inference_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/tokenadmission"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func newTokenAdmissionPolicy(t *testing.T) tokenadmission.Policy {
	t.Helper()
	logger := quietLogger()
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	obs := observation.New(observation.Dependencies{Store: st, Registry: registry.New(logger), Logger: logger})
	t.Cleanup(obs.Close)
	ac := access.New(st, logger, 64<<20, access.Hooks{SetOutcomeStage: observation.SetOutcomeStage, StampAuth: observation.StampAuth})
	ac.SetRateObservation(obs.Incr, observation.StampRateLimit)
	return tokenadmission.Policy{Access: ac, Observation: obs}
}
