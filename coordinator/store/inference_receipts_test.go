package store

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"sync"
	"testing"
	"time"
)

func TestInferenceReceiptTransitionsAndIdempotence(t *testing.T) {
	for name, st := range inferenceReceiptBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			rec := pendingReceipt(uniqueID("receipt-job"), now, now.Add(time.Hour))
			if err := st.CreateInferenceReceipt(ctx, rec); err != nil {
				t.Fatalf("CreateInferenceReceipt: %v", err)
			}

			before, err := st.GetInferenceReceiptByJobID(ctx, rec.JobID)
			if err != nil || before.State != InferenceReceiptPending {
				t.Fatalf("pending read = (%+v, %v)", before, err)
			}

			envelope := []byte(`{"receipt":"first"}`)
			completedAt := now.Add(5 * time.Minute)
			expiresAt := now.Add(2 * time.Hour)
			changed, err := st.CompleteInferenceReceipt(ctx, rec.JobID, "hash-first", envelope, completedAt, expiresAt)
			if err != nil || !changed {
				t.Fatalf("CompleteInferenceReceipt = (%v, %v), want (true, nil)", changed, err)
			}

			// An exact repeat is harmless, and a conflicting completion must not
			// replace the first completed content or timestamps.
			if _, err := st.CompleteInferenceReceipt(ctx, rec.JobID, "hash-first", envelope, completedAt, expiresAt); err != nil {
				t.Fatalf("idempotent CompleteInferenceReceipt: %v", err)
			}
			changed, err = st.CompleteInferenceReceipt(ctx, rec.JobID, "hash-second", []byte(`{"receipt":"second"}`), completedAt.Add(time.Minute), expiresAt.Add(time.Hour))
			if err != nil || changed {
				t.Fatalf("conflicting CompleteInferenceReceipt = (%v, %v), want (false, nil)", changed, err)
			}
			got, err := st.GetInferenceReceiptByJobID(ctx, rec.JobID)
			if err != nil {
				t.Fatalf("GetInferenceReceiptByJobID: %v", err)
			}
			if got.State != InferenceReceiptCompleted || got.ReceiptHash != "hash-first" || got.Nonce != rec.Nonce || string(got.Envelope) != string(envelope) || !got.UpdatedAt.Equal(completedAt) || !got.ExpiresAt.Equal(expiresAt) {
				t.Fatalf("completion was mutated: %+v", got)
			}
			if _, err := st.GetInferenceReceiptByHash(ctx, "hash-first"); err != nil {
				t.Fatalf("GetInferenceReceiptByHash(completed): %v", err)
			}
			if err := st.SetInferenceReceiptState(ctx, rec.JobID, InferenceReceiptFailed, now.Add(10*time.Minute)); err != nil {
				t.Fatalf("SetInferenceReceiptState after completion: %v", err)
			}
			got, err = st.GetInferenceReceiptByJobID(ctx, rec.JobID)
			if err != nil || got.State != InferenceReceiptCompleted {
				t.Fatalf("terminal completion downgraded: (%+v, %v)", got, err)
			}

			failed := pendingReceipt(uniqueID("receipt-failed"), now, now.Add(time.Hour))
			if err := st.CreateInferenceReceipt(ctx, failed); err != nil {
				t.Fatalf("CreateInferenceReceipt(failed case): %v", err)
			}
			if err := st.SetInferenceReceiptState(ctx, failed.JobID, InferenceReceiptFailed, now.Add(time.Minute)); err != nil {
				t.Fatalf("SetInferenceReceiptState: %v", err)
			}
			if err := st.SetInferenceReceiptState(ctx, failed.JobID, InferenceReceiptInterrupted, now.Add(2*time.Minute)); err != nil {
				t.Fatalf("SetInferenceReceiptState terminal repeat: %v", err)
			}
			got, err = st.GetInferenceReceiptByJobID(ctx, failed.JobID)
			if err != nil || got.State != InferenceReceiptFailed {
				t.Fatalf("terminal failure changed: (%+v, %v)", got, err)
			}

			interrupted := pendingReceipt(uniqueID("receipt-interrupted"), now, now.Add(time.Hour))
			if err := st.CreateInferenceReceipt(ctx, interrupted); err != nil {
				t.Fatalf("CreateInferenceReceipt(interrupted case): %v", err)
			}
			if err := st.SetInferenceReceiptState(ctx, interrupted.JobID, InferenceReceiptInterrupted, now.Add(time.Minute)); err != nil {
				t.Fatalf("SetInferenceReceiptState(interrupted): %v", err)
			}
			got, err = st.GetInferenceReceiptByJobID(ctx, interrupted.JobID)
			if err != nil || got.State != InferenceReceiptInterrupted {
				t.Fatalf("pending receipt did not transition to interrupted: (%+v, %v)", got, err)
			}
		})
	}
}

func TestInferenceReceiptDefensiveCopiesAndHashLookup(t *testing.T) {
	for name, st := range inferenceReceiptBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			envelope := []byte(`{"receipt":"stored"}`)
			rec := InferenceReceiptRecord{
				JobID:       uniqueID("receipt-completed"),
				Nonce:       uniqueReceiptNonce(),
				ReceiptHash: uniqueID("receipt-hash"),
				State:       InferenceReceiptCompleted,
				Envelope:    envelope,
				CreatedAt:   now,
				UpdatedAt:   now,
				ExpiresAt:   now.Add(time.Hour),
			}
			if err := st.CreateInferenceReceipt(ctx, rec); err != nil {
				t.Fatalf("CreateInferenceReceipt(completed): %v", err)
			}
			envelope[0] = '!'
			got, err := st.GetInferenceReceiptByJobID(ctx, rec.JobID)
			if err != nil || string(got.Envelope) != `{"receipt":"stored"}` {
				t.Fatalf("CreateInferenceReceipt retained caller bytes: (%+v, %v)", got, err)
			}
			got.Envelope[0] = '!'
			again, err := st.GetInferenceReceiptByHash(ctx, rec.ReceiptHash)
			if err != nil || string(again.Envelope) != `{"receipt":"stored"}` {
				t.Fatalf("lookup returned aliased bytes: (%+v, %v)", again, err)
			}

			pending := pendingReceipt(uniqueID("receipt-pending-hash"), now, now.Add(time.Hour))
			if err := st.CreateInferenceReceipt(ctx, pending); err != nil {
				t.Fatalf("CreateInferenceReceipt(pending): %v", err)
			}
			pendingRead, err := st.GetInferenceReceiptByJobID(ctx, pending.JobID)
			if err != nil || pendingRead.Nonce != pending.Nonce {
				t.Fatalf("pending nonce not persisted: (%+v, %v)", pendingRead, err)
			}
			if _, err := st.GetInferenceReceiptByHash(ctx, ""); !errors.Is(err, ErrNotFound) {
				t.Fatalf("GetInferenceReceiptByHash(empty/pending) = %v, want ErrNotFound", err)
			}
			if _, err := st.GetInferenceReceiptByHash(ctx, pending.JobID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("GetInferenceReceiptByHash(pending) = %v, want ErrNotFound", err)
			}

			completedFromPending := pendingReceipt(uniqueID("receipt-completed-copy"), now, now.Add(time.Hour))
			if err := st.CreateInferenceReceipt(ctx, completedFromPending); err != nil {
				t.Fatalf("CreateInferenceReceipt(completion copy): %v", err)
			}
			completionEnvelope := []byte(`{"receipt":"completion"}`)
			if changed, err := st.CompleteInferenceReceipt(ctx, completedFromPending.JobID, uniqueID("receipt-completion-hash"), completionEnvelope, now.Add(time.Minute), now.Add(2*time.Hour)); err != nil || !changed {
				t.Fatalf("CompleteInferenceReceipt(copy) = (%v, %v)", changed, err)
			}
			completionEnvelope[0] = '!'
			got, err = st.GetInferenceReceiptByJobID(ctx, completedFromPending.JobID)
			if err != nil || string(got.Envelope) != `{"receipt":"completion"}` {
				t.Fatalf("CompleteInferenceReceipt retained caller bytes: (%+v, %v)", got, err)
			}
		})
	}
}

func TestInferenceReceiptHashLookupHidesExpiredCompletedReceipts(t *testing.T) {
	for name, st := range inferenceReceiptBackends(t) {
		t.Run(name, func(t *testing.T) {
			now := time.Now().UTC().Truncate(time.Microsecond)
			rec := completedReceipt(uniqueID("receipt-expired-hash"), uniqueID("receipt-expired-hash-value"), now.Add(-time.Hour), now.Add(-time.Minute))
			if err := st.CreateInferenceReceipt(context.Background(), rec); err != nil {
				t.Fatalf("CreateInferenceReceipt(expired): %v", err)
			}
			if _, err := st.GetInferenceReceiptByHash(context.Background(), rec.ReceiptHash); !errors.Is(err, ErrNotFound) {
				t.Fatalf("GetInferenceReceiptByHash(expired) = %v, want ErrNotFound", err)
			}
		})
	}
}

func TestCompleteInferenceReceiptMissingJobReturnsNotFound(t *testing.T) {
	for name, st := range inferenceReceiptBackends(t) {
		t.Run(name, func(t *testing.T) {
			now := time.Now().UTC().Truncate(time.Microsecond)
			_, err := st.CompleteInferenceReceipt(context.Background(), uniqueID("receipt-missing"), "hash-missing", []byte("envelope"), now, now.Add(time.Hour))
			if !errors.Is(err, ErrNotFound) {
				t.Fatalf("CompleteInferenceReceipt(missing) error = %v, want ErrNotFound", err)
			}
		})
	}
}

func TestInferenceReceiptNonceIsGloballySingleUseAndImmutable(t *testing.T) {
	for name, st := range inferenceReceiptBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			first := pendingReceipt(uniqueID("receipt-nonce-first"), now, now.Add(time.Hour))
			if err := st.CreateInferenceReceipt(ctx, first); err != nil {
				t.Fatalf("CreateInferenceReceipt(first): %v", err)
			}
			if changed, err := st.CompleteInferenceReceipt(ctx, first.JobID, uniqueID("receipt-nonce-hash"), []byte("envelope"), now.Add(time.Minute), now.Add(2*time.Hour)); err != nil || !changed {
				t.Fatalf("CompleteInferenceReceipt(first) = (%v, %v)", changed, err)
			}
			completed, err := st.GetInferenceReceiptByJobID(ctx, first.JobID)
			if err != nil || completed.Nonce != first.Nonce {
				t.Fatalf("completion changed nonce: (%+v, %v)", completed, err)
			}

			second := pendingReceipt(uniqueID("receipt-nonce-second"), now, now.Add(time.Hour))
			second.Nonce = first.Nonce
			if err := st.CreateInferenceReceipt(ctx, second); !errors.Is(err, ErrInferenceReceiptConflict) {
				t.Fatalf("CreateInferenceReceipt(duplicate nonce) = %v, want ErrInferenceReceiptConflict", err)
			}
		})
	}
}

func TestCompleteInferenceReceiptConcurrentTransitionIsSingleWinner(t *testing.T) {
	for name, st := range inferenceReceiptBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			rec := pendingReceipt(uniqueID("receipt-concurrent"), now, now.Add(time.Hour))
			if err := st.CreateInferenceReceipt(ctx, rec); err != nil {
				t.Fatalf("CreateInferenceReceipt: %v", err)
			}

			const callers = 8
			type result struct {
				transitioned bool
				err          error
			}
			results := make(chan result, callers)
			var wg sync.WaitGroup
			for i := 0; i < callers; i++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					changed, err := st.CompleteInferenceReceipt(ctx, rec.JobID, "hash-concurrent", []byte("envelope"), now.Add(time.Minute), now.Add(2*time.Hour))
					results <- result{transitioned: changed, err: err}
				}()
			}
			wg.Wait()
			close(results)
			winners := 0
			for result := range results {
				if result.err != nil {
					t.Fatalf("concurrent completion: %v", result.err)
				}
				if result.transitioned {
					winners++
				}
			}
			if winners != 1 {
				t.Fatalf("successful transitions = %d, want exactly 1", winners)
			}
		})
	}
}

func TestInterruptStaleInferenceReceiptsOldestFirstAndBoundaryInclusive(t *testing.T) {
	for name, st := range inferenceReceiptBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			staleBefore := now.Add(-time.Hour)
			prefix := uniqueID("receipt-stale-order")
			records := []InferenceReceiptRecord{
				pendingReceipt(prefix+"-oldest", now.Add(-4*time.Hour), now.Add(time.Hour)),
				pendingReceipt(prefix+"-tie-a", now.Add(-3*time.Hour), now.Add(time.Hour)),
				pendingReceipt(prefix+"-tie-z", now.Add(-3*time.Hour), now.Add(time.Hour)),
				pendingReceipt(prefix+"-boundary", staleBefore, now.Add(time.Hour)),
				pendingReceipt(prefix+"-recent", staleBefore.Add(time.Second), now.Add(time.Hour)),
			}
			for _, rec := range records {
				if err := st.CreateInferenceReceipt(ctx, rec); err != nil {
					t.Fatalf("CreateInferenceReceipt(%s): %v", rec.JobID, err)
				}
			}
			completed := completedReceipt(prefix+"-completed", uniqueID("receipt-stale-completed-hash"), now.Add(-5*time.Hour), now.Add(time.Hour))
			if err := st.CreateInferenceReceipt(ctx, completed); err != nil {
				t.Fatalf("CreateInferenceReceipt(completed): %v", err)
			}

			interruptedAt := now
			count, err := st.InterruptStaleInferenceReceipts(ctx, staleBefore, interruptedAt, 3)
			if err != nil || count != 3 {
				t.Fatalf("InterruptStaleInferenceReceipts(first) = (%d, %v), want (3, nil)", count, err)
			}
			for i, rec := range records {
				got, err := st.GetInferenceReceiptByJobID(ctx, rec.JobID)
				if err != nil {
					t.Fatalf("GetInferenceReceiptByJobID(%s): %v", rec.JobID, err)
				}
				wantState := InferenceReceiptPending
				if i < 3 {
					wantState = InferenceReceiptInterrupted
					if !got.UpdatedAt.Equal(interruptedAt) || got.Nonce != rec.Nonce || got.ReceiptHash != "" || len(got.Envelope) != 0 {
						t.Fatalf("interrupted receipt content/timestamp changed incorrectly: %+v", got)
					}
				}
				if got.State != wantState {
					t.Fatalf("state for %s = %q, want %q", rec.JobID, got.State, wantState)
				}
			}
			count, err = st.InterruptStaleInferenceReceipts(ctx, staleBefore, interruptedAt, 1)
			if err != nil || count != 1 {
				t.Fatalf("InterruptStaleInferenceReceipts(boundary) = (%d, %v), want (1, nil)", count, err)
			}
			boundary, err := st.GetInferenceReceiptByJobID(ctx, records[3].JobID)
			if err != nil || boundary.State != InferenceReceiptInterrupted || !boundary.UpdatedAt.Equal(interruptedAt) {
				t.Fatalf("stale boundary row not interrupted: (%+v, %v)", boundary, err)
			}
			recent, err := st.GetInferenceReceiptByJobID(ctx, records[4].JobID)
			if err != nil || recent.State != InferenceReceiptPending {
				t.Fatalf("recent pending row changed: (%+v, %v)", recent, err)
			}
			completedRead, err := st.GetInferenceReceiptByJobID(ctx, completed.JobID)
			if err != nil || completedRead.State != InferenceReceiptCompleted {
				t.Fatalf("completed row changed: (%+v, %v)", completedRead, err)
			}
		})
	}
}

func TestInterruptStaleInferenceReceiptsRejectsTimestampBeforeCreation(t *testing.T) {
	for name, st := range inferenceReceiptBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			rec := pendingReceipt(uniqueID("receipt-stale-invalid-time"), now, now.Add(time.Hour))
			if err := st.CreateInferenceReceipt(ctx, rec); err != nil {
				t.Fatalf("CreateInferenceReceipt: %v", err)
			}
			if _, err := st.InterruptStaleInferenceReceipts(ctx, now.Add(time.Second), now.Add(-time.Second), 1); err == nil {
				t.Fatal("InterruptStaleInferenceReceipts accepted interruptedAt before CreatedAt")
			}
			got, err := st.GetInferenceReceiptByJobID(ctx, rec.JobID)
			if err != nil || got.State != InferenceReceiptPending {
				t.Fatalf("invalid timestamp changed receipt: (%+v, %v)", got, err)
			}
			if _, err := st.InterruptStaleInferenceReceipts(ctx, now, time.Time{}, 1); err == nil {
				t.Fatal("InterruptStaleInferenceReceipts accepted zero interruptedAt")
			}
		})
	}
}

func TestInterruptStaleInferenceReceiptsConcurrentBatchIsSingleTransition(t *testing.T) {
	for name, st := range inferenceReceiptBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			const count = 12
			for i := 0; i < count; i++ {
				rec := pendingReceipt(uniqueID("receipt-stale-concurrent"), now.Add(-time.Hour), now.Add(time.Hour))
				if err := st.CreateInferenceReceipt(ctx, rec); err != nil {
					t.Fatalf("CreateInferenceReceipt: %v", err)
				}
			}

			const callers = 6
			results := make(chan struct {
				count int
				err   error
			}, callers)
			var wg sync.WaitGroup
			for i := 0; i < callers; i++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					changed, err := st.InterruptStaleInferenceReceipts(ctx, now, now.Add(time.Minute), count)
					results <- struct {
						count int
						err   error
					}{changed, err}
				}()
			}
			wg.Wait()
			close(results)
			interrupted := 0
			for result := range results {
				if result.err != nil {
					t.Fatalf("concurrent stale interruption: %v", result.err)
				}
				interrupted += result.count
			}
			if interrupted != count {
				t.Fatalf("total interrupted rows = %d, want %d", interrupted, count)
			}
		})
	}
}

func TestInferenceReceiptRejectsTransitionTimestampsBeforeCreation(t *testing.T) {
	for name, st := range inferenceReceiptBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			completed := pendingReceipt(uniqueID("receipt-old-complete"), now, now.Add(time.Hour))
			if err := st.CreateInferenceReceipt(ctx, completed); err != nil {
				t.Fatalf("CreateInferenceReceipt(completion): %v", err)
			}
			beforeCreated := now.Add(-time.Second)
			if _, err := st.CompleteInferenceReceipt(ctx, completed.JobID, "hash-old-complete", []byte("envelope"), beforeCreated, now.Add(time.Hour)); err == nil {
				t.Fatal("CompleteInferenceReceipt accepted completedAt before CreatedAt")
			}
			got, err := st.GetInferenceReceiptByJobID(ctx, completed.JobID)
			if err != nil || got.State != InferenceReceiptPending {
				t.Fatalf("invalid completion changed state: (%+v, %v)", got, err)
			}

			for _, state := range []string{InferenceReceiptFailed, InferenceReceiptInterrupted} {
				rec := pendingReceipt(uniqueID("receipt-old-state"), now, now.Add(time.Hour))
				if err := st.CreateInferenceReceipt(ctx, rec); err != nil {
					t.Fatalf("CreateInferenceReceipt(%s): %v", state, err)
				}
				if err := st.SetInferenceReceiptState(ctx, rec.JobID, state, beforeCreated); err == nil {
					t.Fatalf("SetInferenceReceiptState(%s) accepted updatedAt before CreatedAt", state)
				}
				got, err := st.GetInferenceReceiptByJobID(ctx, rec.JobID)
				if err != nil || got.State != InferenceReceiptPending {
					t.Fatalf("invalid %s transition changed state: (%+v, %v)", state, got, err)
				}
			}
		})
	}
}

func TestPruneInferenceReceiptsOnlyExpiredTerminalRowsAndHonorsLimit(t *testing.T) {
	for name, st := range inferenceReceiptBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			cutoff := now
			pending := pendingReceipt(uniqueID("receipt-prune-pending"), now.Add(-time.Hour), cutoff.Add(time.Hour))
			if err := st.CreateInferenceReceipt(ctx, pending); err != nil {
				t.Fatalf("CreateInferenceReceipt(pending): %v", err)
			}
			completed := completedReceipt(uniqueID("receipt-prune-completed"), uniqueID("receipt-prune-hash"), now.Add(-2*time.Hour), cutoff)
			if err := st.CreateInferenceReceipt(ctx, completed); err != nil {
				t.Fatalf("CreateInferenceReceipt(completed): %v", err)
			}
			failed := pendingReceipt(uniqueID("receipt-prune-failed"), now.Add(-2*time.Hour), cutoff)
			if err := st.CreateInferenceReceipt(ctx, failed); err != nil {
				t.Fatalf("CreateInferenceReceipt(failed): %v", err)
			}
			if err := st.SetInferenceReceiptState(ctx, failed.JobID, InferenceReceiptFailed, now.Add(-time.Hour)); err != nil {
				t.Fatalf("SetInferenceReceiptState(failed): %v", err)
			}
			live := completedReceipt(uniqueID("receipt-prune-live"), uniqueID("receipt-prune-hash"), now, now.Add(time.Hour))
			if err := st.CreateInferenceReceipt(ctx, live); err != nil {
				t.Fatalf("CreateInferenceReceipt(live): %v", err)
			}

			deleted, err := st.PruneInferenceReceipts(ctx, cutoff, 1)
			if err != nil || deleted != 1 {
				t.Fatalf("PruneInferenceReceipts(first) = (%d, %v), want (1, nil)", deleted, err)
			}
			deleted, err = st.PruneInferenceReceipts(ctx, cutoff, 10)
			if err != nil || deleted != 1 {
				t.Fatalf("PruneInferenceReceipts(second) = (%d, %v), want (1, nil)", deleted, err)
			}
			for _, jobID := range []string{completed.JobID, failed.JobID} {
				if _, err := st.GetInferenceReceiptByJobID(ctx, jobID); !errors.Is(err, ErrNotFound) {
					t.Fatalf("pruned receipt %q lookup = %v, want ErrNotFound", jobID, err)
				}
			}
			for _, jobID := range []string{pending.JobID, live.JobID} {
				if _, err := st.GetInferenceReceiptByJobID(ctx, jobID); err != nil {
					t.Fatalf("retained receipt %q lookup: %v", jobID, err)
				}
			}
		})
	}
}

func TestPruneInferenceReceiptsDeletesExpiredPendingRows(t *testing.T) {
	for name, st := range inferenceReceiptBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			expired := pendingReceipt(uniqueID("receipt-prune-expired-pending"), now.Add(-time.Hour), now)
			recent := pendingReceipt(uniqueID("receipt-prune-recent-pending"), now.Add(-time.Hour), now.Add(time.Hour))
			for _, rec := range []InferenceReceiptRecord{expired, recent} {
				if err := st.CreateInferenceReceipt(ctx, rec); err != nil {
					t.Fatalf("CreateInferenceReceipt(%s): %v", rec.JobID, err)
				}
			}
			deleted, err := st.PruneInferenceReceipts(ctx, now, 10)
			if err != nil || deleted != 1 {
				t.Fatalf("PruneInferenceReceipts = (%d, %v), want (1, nil)", deleted, err)
			}
			if _, err := st.GetInferenceReceiptByJobID(ctx, expired.JobID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("expired pending lookup = %v, want ErrNotFound", err)
			}
			if _, err := st.GetInferenceReceiptByJobID(ctx, recent.JobID); err != nil {
				t.Fatalf("recent pending lookup: %v", err)
			}
		})
	}
}

func TestInferenceReceiptRejectsInvalidInput(t *testing.T) {
	for name, st := range inferenceReceiptBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC()
			valid := pendingReceipt(uniqueID("receipt-invalid"), now, now.Add(time.Hour))
			cases := []struct {
				name string
				rec  InferenceReceiptRecord
			}{
				{"blank job id", InferenceReceiptRecord{State: InferenceReceiptPending, CreatedAt: now, UpdatedAt: now, ExpiresAt: now.Add(time.Hour)}},
				{"blank state", func() InferenceReceiptRecord {
					r := valid
					r.JobID = uniqueID("receipt-invalid")
					r.State = ""
					return r
				}()},
				{"unknown state", func() InferenceReceiptRecord {
					r := valid
					r.JobID = uniqueID("receipt-invalid")
					r.State = "unknown"
					return r
				}()},
				{"missing expiry", func() InferenceReceiptRecord {
					r := valid
					r.JobID = uniqueID("receipt-invalid")
					r.ExpiresAt = time.Time{}
					return r
				}()},
				{"expiry before creation", func() InferenceReceiptRecord {
					r := valid
					r.JobID = uniqueID("receipt-invalid")
					r.ExpiresAt = r.CreatedAt
					return r
				}()},
				{"completed without hash", func() InferenceReceiptRecord {
					r := valid
					r.JobID = uniqueID("receipt-invalid")
					r.State = InferenceReceiptCompleted
					r.Envelope = []byte(`{"ok":true}`)
					return r
				}()},
				{"completed without envelope", func() InferenceReceiptRecord {
					r := valid
					r.JobID = uniqueID("receipt-invalid")
					r.State = InferenceReceiptCompleted
					r.ReceiptHash = "hash"
					return r
				}()},
				{"pending with receipt hash", func() InferenceReceiptRecord {
					r := valid
					r.JobID = uniqueID("receipt-invalid")
					r.ReceiptHash = "hash"
					return r
				}()},
				{"missing nonce", func() InferenceReceiptRecord {
					r := valid
					r.JobID = uniqueID("receipt-invalid")
					r.Nonce = ""
					return r
				}()},
				{"malformed nonce", func() InferenceReceiptRecord {
					r := valid
					r.JobID = uniqueID("receipt-invalid")
					r.Nonce = "not-a-canonical-32-byte-base64url-nonce"
					return r
				}()},
				{"padded nonce", func() InferenceReceiptRecord {
					r := valid
					r.JobID = uniqueID("receipt-invalid")
					r.Nonce += "="
					return r
				}()},
				{"invalid base64url alphabet", func() InferenceReceiptRecord {
					r := valid
					r.JobID = uniqueID("receipt-invalid")
					r.Nonce = "+" + r.Nonce[1:]
					return r
				}()},
				{"noncanonical trailing bits", func() InferenceReceiptRecord {
					r := valid
					r.JobID = uniqueID("receipt-invalid")
					r.Nonce = r.Nonce[:42] + "B"
					return r
				}()},
			}
			for _, tc := range cases {
				t.Run(tc.name, func(t *testing.T) {
					if err := st.CreateInferenceReceipt(ctx, tc.rec); err == nil {
						t.Fatalf("CreateInferenceReceipt(%s) succeeded; want validation error", tc.name)
					}
				})
			}
			if err := st.CreateInferenceReceipt(ctx, valid); err != nil {
				t.Fatalf("CreateInferenceReceipt(valid): %v", err)
			}
			if _, err := st.CompleteInferenceReceipt(ctx, valid.JobID, "", []byte(`{"ok":true}`), now.Add(time.Minute), now.Add(time.Hour)); err == nil {
				t.Fatal("CompleteInferenceReceipt accepted empty receipt hash")
			}
			if _, err := st.CompleteInferenceReceipt(ctx, valid.JobID, "hash", nil, now.Add(time.Minute), now.Add(time.Hour)); err == nil {
				t.Fatal("CompleteInferenceReceipt accepted empty envelope")
			}
			if _, err := st.CompleteInferenceReceipt(ctx, valid.JobID, "hash", []byte(`{"ok":true}`), now.Add(time.Minute), now); err == nil {
				t.Fatal("CompleteInferenceReceipt accepted expiry before completion")
			}
			if err := st.SetInferenceReceiptState(ctx, valid.JobID, InferenceReceiptCompleted, now.Add(time.Minute)); err == nil {
				t.Fatal("SetInferenceReceiptState accepted completed state")
			}
			if err := st.SetInferenceReceiptState(ctx, valid.JobID, InferenceReceiptFailed, time.Time{}); err == nil {
				t.Fatal("SetInferenceReceiptState accepted zero updatedAt")
			}
		})
	}
}

func pendingReceipt(jobID string, createdAt, expiresAt time.Time) InferenceReceiptRecord {
	return InferenceReceiptRecord{
		JobID:     jobID,
		Nonce:     uniqueReceiptNonce(),
		State:     InferenceReceiptPending,
		CreatedAt: createdAt,
		UpdatedAt: createdAt,
		ExpiresAt: expiresAt,
	}
}

func completedReceipt(jobID, receiptHash string, createdAt, expiresAt time.Time) InferenceReceiptRecord {
	return InferenceReceiptRecord{
		JobID:       jobID,
		Nonce:       uniqueReceiptNonce(),
		ReceiptHash: receiptHash,
		State:       InferenceReceiptCompleted,
		Envelope:    []byte(`{"receipt":"stored"}`),
		CreatedAt:   createdAt,
		UpdatedAt:   createdAt,
		ExpiresAt:   expiresAt,
	}
}

func uniqueReceiptNonce() string {
	seed := uniqueID("receipt-nonce")
	value := sha256.Sum256([]byte(seed))
	return base64.RawURLEncoding.EncodeToString(value[:])
}

// inferenceReceiptBackends returns every configured backend through the
// optional receipt capability, the same way the API discovers it.
func inferenceReceiptBackends(t *testing.T) map[string]InferenceReceiptStore {
	t.Helper()
	backends := make(map[string]InferenceReceiptStore)
	for name, st := range storeBackends(t) {
		receipts, ok := As[InferenceReceiptStore](st)
		if !ok {
			t.Fatalf("%s store does not implement InferenceReceiptStore", name)
		}
		backends[name] = receipts
	}
	return backends
}
