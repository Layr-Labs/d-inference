package provider_test

import (
	"context"
	"errors"
	"io"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"nhooyr.io/websocket"
)

func TestAutopilotConsentCaptureStorageFailurePreservesFIFOAndDeadline(t *testing.T) {
	f := newConsentSocket(t, nil)
	var mode atomic.Int32
	mode.Store(1)
	f.store.failBeforeConsent(func(ctx context.Context, consent earningsfloor.Consent) error {
		switch mode.Load() {
		case 1:
			return io.ErrUnexpectedEOF
		case 2:
			if !consent.OptedIn {
				<-ctx.Done()
				return ctx.Err()
			}
		}
		return nil
	})
	f.register(t, savedConsent(true))
	first := f.store.snapshot()[0].consent
	f.heartbeat(t, savedConsent(true), 1)
	f.heartbeat(t, savedConsent(false), 2)
	calls := f.store.snapshot()
	if len(calls) != 3 {
		t.Fatalf("storage failure should stop each flush at its head: %+v", calls)
	}
	for _, call := range calls {
		if call.consent != first || !errors.Is(call.err, io.ErrUnexpectedEOF) {
			t.Fatalf("retry rebased or dropped the earliest consent: %+v", calls)
		}
	}
	mode.Store(2)
	started := time.Now()
	f.write(t, map[string]any{"type": protocol.TypeAttestationResponse})
	f.sync(t)
	elapsed := time.Since(started)
	calls = f.store.snapshot()
	if len(calls) != 5 || !errors.Is(calls[3].err, earningsfloor.ErrIdentity) || !errors.Is(calls[4].err, context.DeadlineExceeded) {
		t.Fatalf("identity did not continue to the later bounded journal write: %+v", calls)
	}
	if calls[3].deadline.IsZero() || !calls[3].deadline.Equal(calls[4].deadline) || calls[4].deadline.Sub(started) > 1100*time.Millisecond || elapsed > 2*time.Second {
		t.Fatalf("flush did not share one one-second deadline: first=%v last=%v elapsed=%v", calls[3].deadline, calls[4].deadline, elapsed)
	}
	if calls[3].consent != first || calls[4].consent.OptedIn || !calls[4].consent.At.After(first.At) || !calls[4].consent.At.Before(started) {
		t.Fatalf("queued transition was lost or assigned retry time: %+v", calls)
	}
	mode.Store(0)
	f.bind(t, first, consentCaptureAccount)
	f.write(t, map[string]any{"type": protocol.TypeCodeAttestationResponse})
	f.sync(t)
	retried := f.store.snapshot()
	if len(retried) != 7 || retried[5].err != nil || retried[6].err != nil || retried[5].consent != first || retried[6].consent != calls[4].consent {
		t.Fatalf("failed journal operations did not recover in FIFO order: %+v", retried)
	}
	rows := f.enrollments(t)
	if len(rows) != 1 || rows[0].OptedIn || !rows[0].FirstObservedAt.Equal(first.At.Truncate(time.Microsecond)) {
		t.Fatalf("retry lost original positive or later opt-out: %+v", rows)
	}
}

func TestAutopilotConsentCapturePartialSuccessPreservesSeparatedDuplicates(t *testing.T) {
	f := newConsentSocket(t, nil)
	f.store.failBeforeConsent(func(context.Context, earningsfloor.Consent) error { return io.ErrUnexpectedEOF })
	f.register(t, savedConsent(true))
	first := f.store.snapshot()[0].consent
	f.heartbeat(t, savedConsent(false), 1)

	// Bind between the first retry and the opt-out, then fail the later opt-in.
	// The two unresolved positives must remain distinct after the opt-out leaves.
	f.store.failBeforeConsent(func(ctx context.Context, declaration earningsfloor.Consent) error {
		if declaration == first {
			return nil
		}
		if declaration.OptedIn {
			return io.ErrUnexpectedEOF
		}
		_, err := f.store.MemoryStore.ObserveMachine(ctx, store.MachineObservation{
			SessionID: declaration.SessionID, AccountID: declaration.AccountID, SEKey: "verified-test-key", At: time.Now().UTC(),
		})
		return err
	})
	f.heartbeat(t, savedConsent(true), 2)
	calls := f.store.snapshot()
	if len(calls) != 5 || calls[2].consent != first || !errors.Is(calls[2].err, earningsfloor.ErrIdentity) || calls[3].err != nil || calls[3].consent.OptedIn || !errors.Is(calls[4].err, io.ErrUnexpectedEOF) {
		t.Fatalf("did not exercise identity failure, successful opt-out, then storage failure: %+v", calls)
	}
	last := calls[4].consent
	if !last.OptedIn || !last.At.After(calls[3].consent.At) || !calls[3].consent.At.After(first.At) {
		t.Fatalf("queued transitions lost their original receive order: %+v", calls)
	}

	// A later failed head leaves the older equal tail unattempted, not redundant.
	// Only this fresh duplicate may be coalesced with that tail.
	f.store.failBeforeConsent(func(context.Context, earningsfloor.Consent) error { return io.ErrUnexpectedEOF })
	f.heartbeat(t, savedConsent(true), 3)
	calls = f.store.snapshot()
	if len(calls) != 6 || calls[5].consent != first || !errors.Is(calls[5].err, io.ErrUnexpectedEOF) {
		t.Fatalf("storage failure did not stop retrying at the original head: %+v", calls)
	}
	f.store.failBeforeConsent(nil)
	f.write(t, map[string]any{"type": protocol.TypeCodeAttestationResponse})
	f.sync(t)
	calls = f.store.snapshot()
	if len(calls) != 8 || calls[6].err != nil || calls[7].err != nil || calls[6].consent != first || calls[7].consent != last {
		t.Fatalf("partial success coalesced distinct original opt-ins: %+v", calls)
	}
	rows := f.enrollments(t)
	if len(rows) != 1 || !rows[0].OptedIn || !rows[0].FirstObservedAt.Equal(first.At.Truncate(time.Microsecond)) || !rows[0].ObservedAt.Equal(last.At.Truncate(time.Microsecond)) {
		t.Fatalf("retry lost the opt-in after the successful opt-out: %+v", rows)
	}
}

func TestAutopilotConsentCaptureQueueOverflowDisconnects(t *testing.T) {
	for _, unavailable := range []bool{false, true} {
		name := "unbound_identity"
		if unavailable {
			name = "journal_unavailable"
		}
		t.Run(name, func(t *testing.T) {
			f := newConsentSocket(t, nil)
			if unavailable {
				f.store.failBeforeConsent(func(context.Context, earningsfloor.Consent) error { return io.ErrUnexpectedEOF })
			}
			f.register(t, savedConsent(true))
			for i := 1; i < 256; i++ {
				f.heartbeat(t, savedConsent(i%2 == 0), uint64(i))
			}
			// A duplicate at the bound adds no pending transition and is safe.
			f.heartbeat(t, savedConsent(false), 256)
			f.write(t, protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, ModelAutopilot: savedConsent(true)})
			select {
			case err := <-f.closed:
				if websocket.CloseStatus(err) != websocket.StatusTryAgainLater {
					t.Fatalf("overflow did not fail explicitly with retryable disconnect: %v", err)
				}
			case <-f.ctx.Done():
				t.Fatal("overflow silently dropped consent or grew the queue")
			}
			seen := make(map[time.Time]bool)
			for _, call := range f.store.snapshot() {
				seen[call.consent.At] = true
			}
			want := 257 // 256 transitions plus the fresh duplicate watermark.
			if unavailable {
				want = 1 // Failed head prevents later attempts, not later queuing.
			}
			if len(seen) != want {
				t.Fatalf("queue bound or adjacent dedup changed: attempted distinct timestamps=%d want=%d", len(seen), want)
			}
		})
	}
}
