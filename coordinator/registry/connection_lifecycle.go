package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// ConnectionMaintenance owns connection removal and reversible trust transitions.
// Implementations must retain the registry's session identity and lock ordering.
type ConnectionMaintenance interface {
	Disconnect(string, *Provider, time.Duration, protocol.CoordinatorInferenceErrorCause) bool
	Sweep(time.Duration)
	MarkUntrusted(string, bool)
	RecoverTransientlyUntrusted(string, *Provider) bool
}

// ConnectionLifecycle performs lifecycle transactions against the same registry
// and provider locks used by registration, heartbeats and routing.
type ConnectionLifecycle struct {
	registry *Registry
}
