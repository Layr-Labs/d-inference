package inference_test

import (
	"net/http"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/backend"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type speculativeFailureFixture struct {
	s        *serverFixture
	r        *http.Request
	config   attempt.RaceConfig
	policy   *retry.Controller
	evidence *retry.TerminalEvidence
	latch    *backend.Latch
}

func newSpeculativeFailureFixture(
	t *testing.T,
	deadline time.Duration,
	speculativeAt time.Duration,
) (*speculativeFailureFixture, *memory.MemoryStore, *registry.Provider, *registry.PendingRequest, *registry.Provider, *registry.PendingRequest) {
	t.Helper()
	s := newTestServerForDispatch(t)
	t.Cleanup(s.Close)
	st, ok := s.store.(*memory.MemoryStore)
	if !ok {
		t.Fatalf("test server store = %T, want *memory.MemoryStore", s.store)
	}
	model := "speculative-route-model"
	register := func(id string) *registry.Provider {
		return s.registry.Register(id, nil, &protocol.RegisterMessage{
			Models: []protocol.ModelInfo{{ID: model, ModelType: "chat"}},
		})
	}
	primary := register("speculative-primary")
	backup := register("speculative-backup")
	pending := func(id string, provider *registry.Provider) *registry.PendingRequest {
		pr := &registry.PendingRequest{
			RequestID:  id,
			Attempt:    0,
			ProviderID: provider.ID,
			Model:      model,
			ChunkCh:    make(chan registry.ProviderChunk, 1),
			AcceptedCh: make(chan struct{}, 1),
			CompleteCh: make(chan protocol.UsageInfo, 1),
			ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
			Timing:     &registry.RequestTiming{},
		}
		provider.AddPending(pr)
		if err := st.RecordInferenceRoute(&store.InferenceRouteRecord{
			RequestID:  pr.RequestID,
			Attempt:    pr.Attempt,
			ProviderID: provider.ID,
			Model:      model,
		}); err != nil {
			t.Fatalf("record route %s: %v", id, err)
		}
		return pr
	}
	primaryPR := pending("speculative-primary-request", primary)
	backupPR := pending("speculative-backup-request", backup)
	req, err := http.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	if err != nil {
		t.Fatal(err)
	}
	d := &speculativeFailureFixture{
		s: s,
		r: req,
		config: attempt.RaceConfig{
			Model: model, Deadline: deadline, SpeculativeAt: speculativeAt,
			Clock: firstcontent.NewClock(time.Time{}, deadline, speculativeAt),
		},
		policy:   retry.New(retry.Config{Model: model, Observation: s.observation}),
		evidence: &retry.TerminalEvidence{},
		latch:    s.NewBackendLatch(),
	}
	return d, st, primary, primaryPR, backup, backupPR
}

// heartbeatSlotKV reports a serving slot with an explicit KV backend for the
// provider, so the real latch resolves a tag instead of unknown.
func heartbeatSlotKV(d *speculativeFailureFixture, p *registry.Provider, backend string) {
	d.s.registry.Heartbeat(p.ID, &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "serving",
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots: []protocol.BackendSlotCapacity{
				{Model: d.config.Model, State: "running", KVBackend: &backend},
			},
		},
	})
}

func assertClearedRoutingAttemptIsNoop(t *testing.T, result attempt.RaceResult, captured outcome.Attempt) {
	t.Helper()
	current := result.Attempt
	target := outcome.CurrentOrCaptured(captured, current.Provider, current.Pending, current.RequestID, 0)
	if target != (outcome.Attempt{}) {
		t.Fatalf("cleared speculative routing state restored captured primary: got %+v", target)
	}
}

func assertSpeculativeRouteOutcomes(
	t *testing.T,
	st *memory.MemoryStore,
	primaryID string,
	primaryCode int,
	backupID string,
	backupCode int,
) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		records := st.InferenceRouteRecordsSince(time.Time{})
		if len(records) == 2 {
			var primary, backup *store.InferenceRouteRecord
			for i := range records {
				switch records[i].RequestID {
				case primaryID:
					rec := records[i]
					primary = &rec
				case backupID:
					rec := records[i]
					backup = &rec
				}
			}
			if primary != nil && backup != nil && primary.FinalStatus != "" && backup.FinalStatus != "" {
				if primary.ErrorCode != primaryCode {
					t.Fatalf("primary error code = %d, want %d; record=%+v", primary.ErrorCode, primaryCode, primary)
				}
				if backup.ErrorCode != backupCode {
					t.Fatalf("backup error code = %d, want %d; record=%+v", backup.ErrorCode, backupCode, backup)
				}
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("did not observe exactly two finalized primary/backup route rows: %+v", st.InferenceRouteRecordsSince(time.Time{}))
}
