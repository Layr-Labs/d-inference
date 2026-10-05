package provider_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/heartbeat"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// heartbeatFixture tests the production ingestor directly, not provider owner
// construction or WebSocket dispatch. It retains only the ingestor's dependencies.
type heartbeatFixture struct {
	registry    *registry.Registry
	observation *observation.Owner
	ingestor    *heartbeat.Ingestor
}

func newHeartbeatFixture(tb testing.TB) *heartbeatFixture {
	tb.Helper()
	logger := quietLogger()
	reg := registry.New(logger)
	obs := observation.New(observation.Dependencies{Registry: reg, Logger: logger})
	tb.Cleanup(obs.Close)
	return &heartbeatFixture{registry: reg, observation: obs, ingestor: heartbeat.New(reg, obs)}
}
