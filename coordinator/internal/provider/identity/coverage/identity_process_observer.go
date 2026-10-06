package coverage

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	codeidentity "github.com/eigeninference/d-inference/coordinator/internal/provider/identity"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type Observer struct {
	store              store.Store
	observation        *observation.Owner
	logger             *slog.Logger
	codeAttestThrottle *codeidentity.Throttle
}

func New(st store.Store, obs *observation.Owner, logger *slog.Logger, throttle *codeidentity.Throttle) *Observer {
	return &Observer{store: st, observation: obs, logger: logger, codeAttestThrottle: throttle}
}
