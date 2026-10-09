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
	if len(calls) != 5 || calls[3].err != nil || !errors.Is(calls[4].err, context.DeadlineExceeded) {
		t.Fatalf("successful unbound journal did not continue to the later bounded write: %+v", calls)
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
	if len(retried) != 6 || retried[5].err != nil || retried[5].consent != calls[4].consent {
		t.Fatalf("successful head was replayed or failed tail did not recover: %+v", retried)
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
	// The durable first positive and pending later positive must remain
	// distinct after the intervening opt-out commits.
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
	if len(calls) != 5 || calls[2].consent != first || calls[2].err != nil || calls[3].err != nil || calls[3].consent.OptedIn || !errors.Is(calls[4].err, io.ErrUnexpectedEOF) {
		t.Fatalf("did not exercise successful first positive/opt-out then storage failure: %+v", calls)
	}
	last := calls[4].consent
	if !last.OptedIn || !last.At.After(calls[3].consent.At) || !calls[3].consent.At.After(first.At) {
		t.Fatalf("queued transitions lost their original receive order: %+v", calls)
	}

	// Only the failed later positive remains queued; a fresh equal heartbeat
	// may coalesce with it, but cannot replay the durable earlier transitions.
	f.store.failBeforeConsent(func(context.Context, earningsfloor.Consent) error { return io.ErrUnexpectedEOF })
	f.heartbeat(t, savedConsent(true), 3)
	calls = f.store.snapshot()
	if len(calls) != 6 || calls[5].consent != last || !errors.Is(calls[5].err, io.ErrUnexpectedEOF) {
		t.Fatalf("storage failure replayed a successful transition or changed the failed head: %+v", calls)
	}
	f.store.failBeforeConsent(nil)
	f.write(t, map[string]any{"type": protocol.TypeCodeAttestationResponse})
	f.sync(t)
	calls = f.store.snapshot()
	if len(calls) != 7 || calls[6].err != nil || calls[6].consent != last {
		t.Fatalf("partial success lost the original later opt-in or replayed durable history: %+v", calls)
	}
	rows := f.enrollments(t)
	if len(rows) != 1 || !rows[0].OptedIn || !rows[0].FirstObservedAt.Equal(first.At.Truncate(time.Microsecond)) || !rows[0].ObservedAt.Equal(last.At.Truncate(time.Microsecond)) {
		t.Fatalf("retry lost the opt-in after the successful opt-out: %+v", rows)
	}
}

func TestAutopilotConsentCaptureUnboundJournalDoesNotFillRetryQueue(t *testing.T) {
	f := newConsentSocket(t, nil)
	f.register(t, savedConsent(true))
	for i := 1; i <= 512; i++ {
		f.heartbeat(t, savedConsent(i%2 == 0), uint64(i))
	}
	calls := f.store.snapshot()
	if len(calls) != 513 {
		t.Fatalf("unbound successful journal did not drain each declaration: %d", len(calls))
	}
	for _, call := range calls {
		if call.err != nil {
			t.Fatalf("unbound journal write failed: %+v", call)
		}
	}
	select {
	case err := <-f.closed:
		t.Fatalf("successful unbound journal exhausted retry queue: %v", err)
	default:
	}
	if rows := f.enrollments(t); len(rows) != 0 {
		t.Fatalf("unbound journal fabricated enrollment: %+v", rows)
	}
}

func TestAutopilotConsentCaptureQueueOverflowDisconnects(t *testing.T) {
	f := newConsentSocket(t, nil)
	f.store.failBeforeConsent(func(context.Context, earningsfloor.Consent) error { return io.ErrUnexpectedEOF })
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
	want := 1 // Failed head prevents later attempts, not later queuing.
	if len(seen) != want {
		t.Fatalf("queue bound or adjacent dedup changed: attempted distinct timestamps=%d want=%d", len(seen), want)
	}
}
