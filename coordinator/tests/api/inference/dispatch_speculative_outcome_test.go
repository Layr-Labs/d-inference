package inference_test

import (
	"net/http"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestPrimaryFailureThenBackupErrorKeepsRecordedAttempts(t *testing.T) {
	d, st, primary, primaryPR, backup, backupPR := newSpeculativeFailureFixture(t, time.Second, 500*time.Millisecond)
	captured := outcome.CaptureAttempt(primary, primaryPR, primaryPR.RequestID, primaryPR.Attempt)
	primaryFailure := protocol.InferenceErrorMessage{
		Error:       "primary failed",
		ErrorReason: "primary_failure",
		StatusCode:  http.StatusInternalServerError,
		FailureCode: protocol.FailureCodeGenerationFailure,
	}
	primaryPR.UsedBackup.Store(true)
	d.s.NewRouteRecorder().Pending(primaryPR, outcome.PreCommitProviderErrorOutcome(primaryPR, primaryFailure))

	backupPR.ErrorCh <- protocol.InferenceErrorMessage{
		Error:       "backup failed",
		ErrorReason: "backup_failure",
		StatusCode:  http.StatusBadGateway,
		FailureCode: protocol.FailureCodeEncryptionFailure,
	}
	result := d.s.NewRace(d.config, d.policy, d.evidence, d.latch, func() {}, nil).WaitBackup(d.r.Context(), attempt.RaceAttempt{}, attempt.RaceAttempt{
		Provider: backup, Pending: backupPR, RequestID: backupPR.RequestID, HeldChunks: nil,
	})
	if got := result.Outcome; got != attempt.Retry {
		t.Fatalf("outcome = %v, want retry", got)
	}
	assertClearedRoutingAttemptIsNoop(t, result, captured)
	assertSpeculativeRouteOutcomes(t, st, primaryPR.RequestID, http.StatusInternalServerError, backupPR.RequestID, http.StatusBadGateway)
}

func TestPrimaryFailureThenBackupTimeoutKeepsRecordedAttempts(t *testing.T) {
	d, st, primary, primaryPR, backup, backupPR := newSpeculativeFailureFixture(t, 20*time.Millisecond, 10*time.Millisecond)
	captured := outcome.CaptureAttempt(primary, primaryPR, primaryPR.RequestID, primaryPR.Attempt)
	primaryFailure := protocol.InferenceErrorMessage{
		Error:       "primary failed",
		ErrorReason: "primary_failure",
		StatusCode:  http.StatusInternalServerError,
		FailureCode: protocol.FailureCodeGenerationFailure,
	}
	primaryPR.UsedBackup.Store(true)
	d.s.NewRouteRecorder().Pending(primaryPR, outcome.PreCommitProviderErrorOutcome(primaryPR, primaryFailure))

	result := d.s.NewRace(d.config, d.policy, d.evidence, d.latch, func() {}, nil).WaitBackup(d.r.Context(), attempt.RaceAttempt{}, attempt.RaceAttempt{
		Provider: backup, Pending: backupPR, RequestID: backupPR.RequestID, HeldChunks: nil,
	})
	if got := result.Outcome; got != attempt.Retry {
		t.Fatalf("outcome = %v, want retry", got)
	}
	assertClearedRoutingAttemptIsNoop(t, result, captured)
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
					FailureCode: protocol.FailureCodeGenerationFailure,
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
			d, _, primary, primaryPR, backup, backupPR := newSpeculativeFailureFixture(t, tc.deadline, tc.speculativeAt)
			heartbeatKV := func(p *registry.Provider, backend *string) {
				d.s.registry.Heartbeat(p.ID, &protocol.HeartbeatMessage{
					Type:   protocol.TypeHeartbeat,
					Status: "serving",
					BackendCapacity: &protocol.BackendCapacity{
						TotalMemoryGB: 64,
						Slots: []protocol.BackendSlotCapacity{
							{Model: d.config.Model, State: "running", KVBackend: backend},
						},
					},
				})
			}
			heartbeatKV(primary, &paged)
			heartbeatKV(backup, &contiguous)

			// Dispatch latched the PRIMARY's slot...
			d.latch.Note(primary, primaryPR, false)
			if got := d.latch.Resolve(primaryPR, false, false).Backend; got != registry.KVBackendPaged {
				t.Fatalf("primary latch = %q, want %q", got, registry.KVBackendPaged)
			}
			// ...then the primary failed: the race records the failure and
			// clears its current attempt before entering the backup wait.
			primaryPR.UsedBackup.Store(true)
			d.s.NewRouteRecorder().Pending(primaryPR, outcome.PreCommitProviderErrorOutcome(primaryPR, protocol.InferenceErrorMessage{
				Error:       "primary failed",
				ErrorReason: "primary_failure",
				StatusCode:  http.StatusInternalServerError,
				FailureCode: protocol.FailureCodeGenerationFailure,
			}))
			current := attempt.RaceAttempt{Pending: nil, Provider: nil, RequestID: ""}

			tc.failBackup(backupPR)
			result := d.s.NewRace(d.config, d.policy, d.evidence, d.latch, func() {}, nil).WaitBackup(d.r.Context(), current, attempt.RaceAttempt{
				Provider: backup, Pending: backupPR, RequestID: backupPR.RequestID, HeldChunks: nil,
			})
			if got := result.Outcome; got != attempt.Retry {
				t.Fatalf("outcome = %v, want retry", got)
			}

			// The exhaustion ladder reads the attribution with Pending cleared:
			// it must name the backup's backend, not the dead primary's.
			_, sticky := d.evidence.Select(retry.TerminalFailure{}, false)
			attr := d.latch.Resolve(result.Attempt.Pending, sticky, sticky)
			if attr.Backend != registry.KVBackendContiguous {
				t.Errorf("terminal attribution = %q, want %q (the backup supplied the last failure)",
					attr.Backend, registry.KVBackendContiguous)
			}
		})
	}
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
	d, _, primary, primaryPR, backup, backupPR := newSpeculativeFailureFixture(t, time.Second, 500*time.Millisecond)
	heartbeatSlotKV(d, primary, registry.KVBackendPaged)
	heartbeatSlotKV(d, backup, registry.KVBackendContiguous)

	// Dispatch latched the primary's slot...
	d.latch.Note(primary, primaryPR, false)

	// ...then the primary failed with a deterministic client 4xx: runRace's
	// ErrorCh arm records the failure, latches the verdict, and clears
	// the current attempt before entering the backup wait.
	verdict := protocol.InferenceErrorMessage{
		Error:       "prompt malformed",
		ErrorReason: "bad_request",
		StatusCode:  http.StatusBadRequest,
		FailureCode: protocol.FailureCodeInvalidRequest,
	}
	primaryPR.UsedBackup.Store(true)
	d.s.NewRouteRecorder().Pending(primaryPR, outcome.PreCommitProviderErrorOutcome(primaryPR, verdict))
	race := d.s.NewRace(d.config, d.policy, d.evidence, d.latch, func() {}, nil)
	decision := race.RecordLoser(primary, verdict)
	if decision == nil || decision.ClientStatusCode == 0 {
		t.Fatal("the primary's 400 must latch a terminal client verdict")
	}
	current := attempt.RaceAttempt{Pending: nil, Provider: nil, RequestID: ""}

	// The backup fails too — its 502 must NOT steal the attribution.
	backupPR.ErrorCh <- protocol.InferenceErrorMessage{
		Error:       "backup failed",
		ErrorReason: "backup_failure",
		StatusCode:  http.StatusBadGateway,
		FailureCode: protocol.FailureCodeGenerationFailure,
	}
	result := race.WaitBackup(d.r.Context(), current, attempt.RaceAttempt{
		Provider: backup, Pending: backupPR, RequestID: backupPR.RequestID, HeldChunks: nil,
	})
	if got := result.Outcome; got != attempt.Retry {
		t.Fatalf("outcome = %v, want retry", got)
	}

	_, sticky := d.evidence.Select(retry.TerminalFailure{}, false)
	frozen := decision.ClientStatusCode != 0 || decision.UnservableReason != ""
	attr := d.latch.Resolve(result.Attempt.Pending, frozen || sticky, sticky)
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
	d, _, primary, primaryPR, backup, backupPR := newSpeculativeFailureFixture(t, time.Second, 500*time.Millisecond)
	heartbeatSlotKV(d, primary, registry.KVBackendPaged)
	heartbeatSlotKV(d, backup, registry.KVBackendContiguous)

	d.latch.Note(primary, primaryPR, false)

	// Promotion outside the choke point: pending moves to the backup with no
	// explicit re-latch.
	pending := backupPR
	if got := d.latch.Resolve(pending, false, false).Backend; got != registry.KVBackendContiguous {
		t.Fatalf("live mismatch read = %q, want the backup's %q", got, registry.KVBackendContiguous)
	}

	// The promoted backup fails pre-content; the wait path clears pending. The
	// exhaustion fallback must name the promoted slot.
	pending = nil
	if got := d.latch.Resolve(pending, false, false).Backend; got != registry.KVBackendContiguous {
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
	d, _, primary, primaryPR, backup, backupPR := newSpeculativeFailureFixture(t, time.Second, 500*time.Millisecond)
	heartbeatSlotKV(d, primary, registry.KVBackendPaged)
	heartbeatSlotKV(d, backup, registry.KVBackendContiguous)

	d.latch.Note(primary, primaryPR, false)
	verdict := protocol.InferenceErrorMessage{
		Error:       "prompt malformed",
		ErrorReason: "bad_request",
		StatusCode:  http.StatusBadRequest,
		FailureCode: protocol.FailureCodeInvalidRequest,
	}
	race := d.s.NewRace(d.config, d.policy, d.evidence, d.latch, func() {}, nil)
	decision := race.RecordLoser(primary, verdict)
	frozen := decision.ClientStatusCode != 0 || decision.UnservableReason != ""
	_, sticky := d.evidence.Select(retry.TerminalFailure{}, false)

	pending := backupPR
	if got := d.latch.Resolve(pending, frozen || sticky, sticky).Backend; got != registry.KVBackendContiguous {
		t.Fatalf("live read = %q, want the backup's %q (live reads stay truthful)", got, registry.KVBackendContiguous)
	}
	pending = nil
	if got := d.latch.Resolve(pending, frozen || sticky, sticky).Backend; got != registry.KVBackendPaged {
		t.Errorf("terminal fallback = %q, want %q (the frozen verdict latch must survive live reads)",
			got, registry.KVBackendPaged)
	}
}

func TestCapturedRoutingAttemptStillHandlesOrdinaryRetry(t *testing.T) {
	_, _, primary, primaryPR, _, _ := newSpeculativeFailureFixture(t, time.Second, 500*time.Millisecond)
	captured := outcome.CaptureAttempt(primary, primaryPR, primaryPR.RequestID, primaryPR.Attempt)

	// Ordinary single-provider failure paths clear provider/pr but retain the
	// request ID so waitFirstChunk's defer can finalize the captured attempt.
	current := attempt.RaceAttempt{RequestID: primaryPR.RequestID}
	target := outcome.CurrentOrCaptured(captured, current.Provider, current.Pending, current.RequestID, primaryPR.Attempt)
	if target != captured {
		t.Fatalf("ordinary retry lost captured attempt: got %+v, want %+v", target, captured)
	}
}
