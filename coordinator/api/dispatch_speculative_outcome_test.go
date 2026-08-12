package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestPrimaryFailureThenBackupErrorKeepsRecordedAttempts(t *testing.T) {
	d, st, primary, primaryPR, backup, backupPR := speculativeFailureTestState(t, time.Second, 500*time.Millisecond)
	captured := routingAttempt(primary, primaryPR, primaryPR.RequestID, primaryPR.Attempt)
	primaryFailure := protocol.InferenceErrorMessage{
		Error:       "primary failed",
		ErrorReason: "primary_failure",
		StatusCode:  http.StatusInternalServerError,
	}
	d.updateSpeculativeFailure(primaryPR, primaryFailure)

	backupPR.ErrorCh <- protocol.InferenceErrorMessage{
		Error:       "backup failed",
		ErrorReason: "backup_failure",
		StatusCode:  http.StatusBadGateway,
		FailureCode: protocol.FailureCodeEncryptionFailure,
	}
	if got := d.racePrimaryFailedWaitBackup(backup, backupPR, nil); got != outcomeRetry {
		t.Fatalf("outcome = %v, want retry", got)
	}
	assertClearedRoutingAttemptIsNoop(t, d, captured)
	assertSpeculativeRouteOutcomes(t, st, primaryPR.RequestID, http.StatusInternalServerError, backupPR.RequestID, http.StatusBadGateway)
}

func TestPrimaryFailureThenBackupTimeoutKeepsRecordedAttempts(t *testing.T) {
	d, st, primary, primaryPR, backup, backupPR := speculativeFailureTestState(t, 20*time.Millisecond, 10*time.Millisecond)
	captured := routingAttempt(primary, primaryPR, primaryPR.RequestID, primaryPR.Attempt)
	primaryFailure := protocol.InferenceErrorMessage{
		Error:       "primary failed",
		ErrorReason: "primary_failure",
		StatusCode:  http.StatusInternalServerError,
	}
	d.updateSpeculativeFailure(primaryPR, primaryFailure)

	if got := d.racePrimaryFailedWaitBackup(backup, backupPR, nil); got != outcomeRetry {
		t.Fatalf("outcome = %v, want retry", got)
	}
	assertClearedRoutingAttemptIsNoop(t, d, captured)
	assertSpeculativeRouteOutcomes(t, st, primaryPR.RequestID, http.StatusInternalServerError, backupPR.RequestID, http.StatusGatewayTimeout)
}

// TestSpeculativeBackupFailureAttributesBackupKVBackend pins the Gate G5
// attribution across a mixed-backend speculative race: the primary serves
// PAGED, the backup CONTIGUOUS, the primary fails first and then the backup's
// own failure (error or timeout) becomes the terminal one. The terminal
// outcome tag must follow the BACKUP — the last slot that actually failed.
// Before racePrimaryFailedWaitBackup re-latched on entry, the ladder fell
// back to the primary's stale latch and booked the backup's 5xx/timeout under
// kv_backend:paged, corrupting exactly the per-backend error segmentation the
// paged rollout is judged on.
func TestSpeculativeBackupFailureAttributesBackupKVBackend(t *testing.T) {
	paged, contiguous := registry.KVBackendPaged, registry.KVBackendContiguous
	for _, tc := range []struct {
		name          string
		deadline      time.Duration
		speculativeAt time.Duration
		failBackup    func(backupPR *registry.PendingRequest)
	}{
		{
			name:          "backup errors",
			deadline:      time.Second,
			speculativeAt: 500 * time.Millisecond,
			failBackup: func(backupPR *registry.PendingRequest) {
				backupPR.ErrorCh <- protocol.InferenceErrorMessage{
					Error:       "backup failed",
					ErrorReason: "backup_failure",
					StatusCode:  http.StatusBadGateway,
				}
			},
		},
		{
			name:          "backup times out",
			deadline:      20 * time.Millisecond,
			speculativeAt: 10 * time.Millisecond,
			failBackup:    func(*registry.PendingRequest) {},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d, _, primary, primaryPR, backup, backupPR := speculativeFailureTestState(t, tc.deadline, tc.speculativeAt)
			heartbeatKV := func(p *registry.Provider, backend *string) {
				d.s.registry.Heartbeat(p.ID, &protocol.HeartbeatMessage{
					Type:   protocol.TypeHeartbeat,
					Status: "serving",
					BackendCapacity: &protocol.BackendCapacity{
						TotalMemoryGB: 64,
						Slots: []protocol.BackendSlotCapacity{
							{Model: d.model, State: "running", KVBackend: backend},
						},
					},
				})
			}
			heartbeatKV(primary, &paged)
			heartbeatKV(backup, &contiguous)

			// Dispatch latched the PRIMARY's slot...
			d.pr = primaryPR
			d.noteServingSlot()
			if got := d.kvBackendAttribution().Backend; got != registry.KVBackendPaged {
				t.Fatalf("primary latch = %q, want %q", got, registry.KVBackendPaged)
			}
			// ...then the primary failed: runRace's ErrorCh arm records the
			// failure and clears d.provider/d.pr/d.requestID before entering
			// the backup wait.
			d.updateSpeculativeFailure(primaryPR, protocol.InferenceErrorMessage{
				Error:       "primary failed",
				ErrorReason: "primary_failure",
				StatusCode:  http.StatusInternalServerError,
			})
			d.pr, d.provider, d.requestID = nil, nil, ""

			tc.failBackup(backupPR)
			if got := d.racePrimaryFailedWaitBackup(backup, backupPR, nil); got != outcomeRetry {
				t.Fatalf("outcome = %v, want retry", got)
			}

			// The exhaustion ladder reads the attribution with d.pr cleared:
			// it must name the backup's backend, not the dead primary's.
			attr := d.kvBackendAttribution()
			if attr.Backend != registry.KVBackendContiguous {
				t.Errorf("terminal attribution = %q, want %q (the backup supplied the last failure)",
					attr.Backend, registry.KVBackendContiguous)
			}
		})
	}
}

// heartbeatSlotKV reports a serving slot with an explicit KV backend for the
// provider, so kvBackendAttribution resolves a real tag instead of unknown.
func heartbeatSlotKV(d *dispatchState, p *registry.Provider, backend string) {
	d.s.registry.Heartbeat(p.ID, &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "serving",
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots: []protocol.BackendSlotCapacity{
				{Model: d.model, State: "running", KVBackend: &backend},
			},
		},
	})
}

// TestDeterministicPrimaryVerdictKeepsPrimaryAttribution pins the freeze rule
// (the deterministic-loser interaction with the backup re-latch): when the
// PRIMARY's failure latches a deterministic terminal verdict — a client 4xx
// identical on every provider — the terminal response IS that verdict no
// matter what the backup does next, so the outcome attribution must keep
// naming the primary's backend. The re-latch on entry to
// racePrimaryFailedWaitBackup is a deliberate no-op in that state; without
// the freeze, the primary's controlling 400 booked under the backup's
// kv_backend tag.
func TestDeterministicPrimaryVerdictKeepsPrimaryAttribution(t *testing.T) {
	d, _, primary, primaryPR, backup, backupPR := speculativeFailureTestState(t, time.Second, 500*time.Millisecond)
	heartbeatSlotKV(d, primary, registry.KVBackendPaged)
	heartbeatSlotKV(d, backup, registry.KVBackendContiguous)

	// Dispatch latched the primary's slot...
	d.pr = primaryPR
	d.noteServingSlot()

	// ...then the primary failed with a deterministic client 4xx: runRace's
	// ErrorCh arm records the failure, latches the verdict, and clears
	// d.provider/d.pr before entering the backup wait.
	verdict := protocol.InferenceErrorMessage{
		Error:       "prompt malformed",
		ErrorReason: "bad_request",
		StatusCode:  http.StatusBadRequest,
	}
	d.updateSpeculativeFailure(primaryPR, verdict)
	d.latchDeterministicLoser(primary, verdict)
	if !d.terminalClientError {
		t.Fatal("the primary's 400 must latch a terminal client verdict")
	}
	d.pr, d.provider, d.requestID = nil, nil, ""

	// The backup fails too — its 502 must NOT steal the attribution.
	backupPR.ErrorCh <- protocol.InferenceErrorMessage{
		Error:       "backup failed",
		ErrorReason: "backup_failure",
		StatusCode:  http.StatusBadGateway,
	}
	if got := d.racePrimaryFailedWaitBackup(backup, backupPR, nil); got != outcomeRetry {
		t.Fatalf("outcome = %v, want retry", got)
	}

	attr := d.kvBackendAttribution()
	if attr.Backend != registry.KVBackendPaged {
		t.Errorf("terminal attribution = %q, want %q (the primary's deterministic 4xx controls the outcome)",
			attr.Backend, registry.KVBackendPaged)
	}
}

// TestPromotedBackupSavedOnLiveMismatch pins the promotion-save: a live
// attribution read through a MISMATCHED d.pr means a backup was promoted
// outside every noteServingSlot site (AcceptedCh / preamble promotion). The
// read must save the resolution, so a promoted backup that then errors or
// times out pre-content — after the wait path clears d.pr — books under its
// own backend, not the cancelled primary's stale latch.
func TestPromotedBackupSavedOnLiveMismatch(t *testing.T) {
	d, _, primary, primaryPR, backup, backupPR := speculativeFailureTestState(t, time.Second, 500*time.Millisecond)
	heartbeatSlotKV(d, primary, registry.KVBackendPaged)
	heartbeatSlotKV(d, backup, registry.KVBackendContiguous)

	d.pr = primaryPR
	d.noteServingSlot()

	// Promotion outside the choke point: d.pr moves to the backup with no
	// explicit re-latch.
	d.pr = backupPR
	if got := d.kvBackendAttribution().Backend; got != registry.KVBackendContiguous {
		t.Fatalf("live mismatch read = %q, want the backup's %q", got, registry.KVBackendContiguous)
	}

	// The promoted backup fails pre-content; the wait path clears d.pr. The
	// exhaustion fallback must name the promoted slot.
	d.pr = nil
	if got := d.kvBackendAttribution().Backend; got != registry.KVBackendContiguous {
		t.Errorf("terminal fallback = %q, want %q (the live mismatch read must save the promotion)",
			got, registry.KVBackendContiguous)
	}
}

// TestFrozenLatchSurvivesLiveMismatchRead pins the interaction of the two
// rules above: once the primary's deterministic verdict latches, a live read
// through a promoted backup stays truthful (returns the backup) but must NOT
// move the persistent latch — the terminal fallback still belongs to the
// verdict slot.
func TestFrozenLatchSurvivesLiveMismatchRead(t *testing.T) {
	d, _, primary, primaryPR, backup, backupPR := speculativeFailureTestState(t, time.Second, 500*time.Millisecond)
	heartbeatSlotKV(d, primary, registry.KVBackendPaged)
	heartbeatSlotKV(d, backup, registry.KVBackendContiguous)

	d.pr = primaryPR
	d.noteServingSlot()
	verdict := protocol.InferenceErrorMessage{
		Error:       "prompt malformed",
		ErrorReason: "bad_request",
		StatusCode:  http.StatusBadRequest,
	}
	d.latchDeterministicLoser(primary, verdict)

	d.pr = backupPR
	if got := d.kvBackendAttribution().Backend; got != registry.KVBackendContiguous {
		t.Fatalf("live read = %q, want the backup's %q (live reads stay truthful)", got, registry.KVBackendContiguous)
	}
	d.pr = nil
	if got := d.kvBackendAttribution().Backend; got != registry.KVBackendPaged {
		t.Errorf("terminal fallback = %q, want %q (the frozen verdict latch must survive live reads)",
			got, registry.KVBackendPaged)
	}
}

func TestCapturedRoutingAttemptStillHandlesOrdinaryRetry(t *testing.T) {
	d, _, primary, primaryPR, _, _ := speculativeFailureTestState(t, time.Second, 500*time.Millisecond)
	captured := routingAttempt(primary, primaryPR, primaryPR.RequestID, primaryPR.Attempt)

	// Ordinary single-provider failure paths clear provider/pr but retain the
	// request ID so waitFirstChunk's defer can finalize the captured attempt.
	d.requestID = primaryPR.RequestID
	target := d.currentOrCapturedRoutingAttempt(captured)
	if target.requestID != captured.requestID || target.pending != captured.pending || target.provider != captured.provider || target.attempt != captured.attempt {
		t.Fatalf("ordinary retry lost captured attempt: got %+v, want %+v", target, captured)
	}
}

func speculativeFailureTestState(
	t *testing.T,
	deadline time.Duration,
	speculativeAt time.Duration,
) (*dispatchState, *store.MemoryStore, *registry.Provider, *registry.PendingRequest, *registry.Provider, *registry.PendingRequest) {
	t.Helper()
	s := newTestServerForDispatch(t)
	st, ok := s.store.(*store.MemoryStore)
	if !ok {
		t.Fatalf("test server store = %T, want *store.MemoryStore", s.store)
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
			ChunkCh:    make(chan string, 1),
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
	d := &dispatchState{
		s:                 s,
		r:                 req,
		model:             model,
		deadline:          deadline,
		speculativeAt:     speculativeAt,
		attempt:           0,
		excludeProviders:  make(map[string]struct{}),
		refundReservation: func() {},
		// runRace deliberately clears these after recording the primary error.
		provider:  nil,
		pr:        nil,
		requestID: "",
	}
	return d, st, primary, primaryPR, backup, backupPR
}

func assertClearedRoutingAttemptIsNoop(t *testing.T, d *dispatchState, captured dispatchRoutingAttempt) {
	t.Helper()
	target := d.currentOrCapturedRoutingAttempt(captured)
	if target != (dispatchRoutingAttempt{}) {
		t.Fatalf("cleared speculative routing state restored captured primary: got %+v", target)
	}
}

func assertSpeculativeRouteOutcomes(
	t *testing.T,
	st *store.MemoryStore,
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
