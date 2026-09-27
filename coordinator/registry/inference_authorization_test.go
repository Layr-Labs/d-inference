package registry

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestAppAttestWriterCancellationCannotTurnDenialIntoSuccess(t *testing.T) {
	r, p, lease := appAttestTestProvider(t)
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant")
	}
	w, frames := appAttestTestWriter(t, p)
	pr := &PendingRequest{RequestID: "cancel-denial", Model: appAttestTestModel}
	if r.ReserveProvider(appAttestTestModel, pr) != p {
		t.Fatal("reserve")
	}
	entered, release := make(chan struct{}), make(chan struct{})
	defer close(release)
	w.afterWriteRejectedForTest = func() { close(entered); <-release }
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := p.WriteInferenceTextDeferred(ctx, pr, func(time.Time) ([]byte, error) { return []byte("sealed"), nil }, func(TextFrameWriteMetadata) { r.ClearAppAttestServingAuthorization(p) })
		done <- err
	}()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("rejection not reached")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, ErrProviderServingUnauthorized) {
			t.Fatalf("denied frame returned %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("cancellation blocked")
	}
	if frames.Load() != 0 {
		t.Fatal("denied frame written")
	}
}

func TestAppAttestQueuedRequestCannotTransferToFreshReplacementLease(t *testing.T) {
	for _, changed := range []string{"endpoint", "account", "machine"} {
		t.Run(changed, func(t *testing.T) {
			r, p, lease := appAttestTestProvider(t)
			if !r.GrantAppAttestServingAuthorization(p, lease) {
				t.Fatal("grant")
			}
			_, frames := appAttestTestWriter(t, p)
			pr := &PendingRequest{RequestID: "rebind", Model: appAttestTestModel}
			if r.ReserveProvider(appAttestTestModel, pr) != p {
				t.Fatal("reserve")
			}
			_, err := p.WriteInferenceTextDeferred(context.Background(), pr, func(time.Time) ([]byte, error) { return []byte("old sealed request"), nil }, func(TextFrameWriteMetadata) {
				switch changed {
				case "endpoint":
					p.mu.Lock()
					p.PublicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
					lease.Endpoint = p.PublicKey
					p.mu.Unlock()
				case "account":
					p.mu.Lock()
					p.AccountID = "replacement-account"
					p.mu.Unlock()
					lease.AccountID = "replacement-account"
				case "machine":
					lease.MachineID = "replacement-machine"
				}
				if !r.BindVerifiedMachineIdentity(p, lease.AccountID, lease.MachineID) || !r.GrantAppAttestServingAuthorization(p, lease) {
					t.Fatal("replacement lease should be valid for future requests")
				}
			})
			if !errors.Is(err, ErrProviderServingUnauthorized) || frames.Load() != 0 {
				t.Fatalf("old request transferred: err=%v frames=%d", err, frames.Load())
			}
		})
	}
}

func TestAppAttestFinalHandoffExpiresWhileWaitingForProviderLock(t *testing.T) {
	r, p, lease := appAttestTestProvider(t)
	lease.ValidUntil = time.Now().Add(50 * time.Millisecond)
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant")
	}
	w, _ := appAttestTestWriter(t, p)
	pr := &PendingRequest{RequestID: "lock-expiry", Model: appAttestTestModel}
	if r.ReserveProvider(appAttestTestModel, pr) != p {
		t.Fatal("reserve")
	}
	p.mu.Lock()
	started, done := make(chan struct{}), make(chan error, 1)
	go func() { close(started); done <- r.authorizeInferenceHandoff(p, pr, w) }()
	<-started
	<-time.After(time.Until(lease.ValidUntil))
	p.mu.Unlock()
	select {
	case err := <-done:
		if !errors.Is(err, ErrProviderServingUnauthorized) {
			t.Fatalf("expired handoff = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("handoff blocked")
	}
}
