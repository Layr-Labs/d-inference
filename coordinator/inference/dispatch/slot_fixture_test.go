package dispatch

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// registerHeartbeatedProvider registers a provider and drives ONE real
// heartbeat carrying the slot's kv_backend, so the test exercises the ingest
// path rather than hand-setting registry state.
func registerHeartbeatedProvider(t *testing.T, srv *Controller, id, model string, backend *string) *registry.Provider {
	t.Helper()
	p := srv.deps.Registry().Register(id, nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	if p == nil {
		t.Fatalf("provider %q did not register", id)
	}
	srv.deps.Registry().Heartbeat(id, &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "serving",
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots: []protocol.BackendSlotCapacity{
				{Model: model, State: "running", KVBackend: backend},
			},
		},
	})
	return p
}
