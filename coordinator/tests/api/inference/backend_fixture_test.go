package inference_test

import (
	"testing"
	"time"

	cacheusage "github.com/eigeninference/d-inference/coordinator/internal/inference/cacheusage"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// registerHeartbeatedProvider registers a provider and drives ONE real
// heartbeat carrying the slot's kv_backend, so the test exercises the ingest
// path rather than hand-setting registry state.
func registerHeartbeatedProvider(t *testing.T, srv *serverFixture, id, model string, backend *string) *registry.Provider {
	t.Helper()
	p := srv.registry.Register(id, nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	if p == nil {
		t.Fatalf("provider %q did not register", id)
	}
	srv.registry.Heartbeat(id, &protocol.HeartbeatMessage{
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

// completedPendingRequest builds a pending request whose Timing yields a
// positive actual_ttft_ms and a measurable decode window, reserves its cost,
// and registers it on the provider so handleComplete settles it normally.
func completedPendingRequest(t *testing.T, srv *serverFixture, p *registry.Provider, reqID, model string, usage protocol.UsageInfo) *registry.PendingRequest {
	t.Helper()
	cost := payments.DefaultRates().CostWithMinimum(cacheusage.Billable(usage))
	if err := srv.ledger.Charge(testConsumerID, cost, "reserve:"+reqID); err != nil {
		t.Fatalf("reserve balance for %s: %v", reqID, err)
	}
	base := time.Now().Add(-2 * time.Second)
	pr := &registry.PendingRequest{
		RequestID:        reqID,
		ProviderID:       p.ID,
		Model:            model,
		ConsumerKey:      testConsumerID,
		ReservedMicroUSD: cost,
		ChunkCh:          make(chan registry.ProviderChunk, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
		Timing: &registry.RequestTiming{
			ReceivedAt:     base.Add(-50 * time.Millisecond),
			DispatchedAt:   base,
			FirstChunkAt:   base.Add(100 * time.Millisecond),
			FirstContentAt: base.Add(250 * time.Millisecond),
		},
	}
	p.AddPending(pr)
	return pr
}
