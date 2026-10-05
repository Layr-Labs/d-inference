package cancellation

import (
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// cancelController owns cancel delivery, terminal correlation, and the
// provider-specific reservation refund. Tracker may be nil for untracked
// best-effort delivery; all other dependencies match the request owner.
type Controller struct {
	Tracker     *Tracker
	Registry    *registry.Registry
	Store       store.Store
	Observation *observation.Owner
	Logger      *slog.Logger
}

// cancelWriteTimeout prevents a half-dead connection from blocking abandonment.
const cancelWriteTimeout = 2 * time.Second
