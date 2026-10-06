package registry_test

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestAppAttestWriterCancellationCannotTurnDenialIntoSuccess(t *testing.T) {
	frames := &atomic.Int32{}
	w := newWriterFixture(8, 8, nil, nil, func([]byte) error { frames.Add(1); return nil }, nil)
	t.Cleanup(w.Close)
	r, p, lease := appAttestTestProvider(t, production.NewWithDependencies(testLogger(), production.Dependencies{
		Connections: retainedWriterFactory{writer: w.Writer},
	}))
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant")
	}
	pr := &production.PendingRequest{RequestID: "cancel-denial", Model: appAttestTestModel}
	if r.ReserveProvider(appAttestTestModel, pr) != p {
		t.Fatal("reserve")
	}
	entered, release := make(chan struct{}), make(chan struct{})
	defer close(release)
	go w.executeUntilPublication(false, entered, release)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := p.WriteInferenceTextDeferred(ctx, pr, func(time.Time) ([]byte, error) { return []byte("sealed"), nil }, func(production.TextFrameWriteMetadata) { r.ClearAppAttestServingAuthorization(p) })
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
		if !errors.Is(err, production.ErrProviderServingUnauthorized) {
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
			frames := &atomic.Int32{}
			w := newWriterFixture(8, 8, nil, nil, func([]byte) error { frames.Add(1); return nil }, nil)
			t.Cleanup(w.Close)
			r, p, lease := appAttestTestProvider(t, production.NewWithDependencies(testLogger(), production.Dependencies{
				Connections: retainedWriterFactory{writer: w.Writer},
			}))
			if !r.GrantAppAttestServingAuthorization(p, lease) {
				t.Fatal("grant")
			}
			go w.Run()
			pr := &production.PendingRequest{RequestID: "rebind", Model: appAttestTestModel}
			if r.ReserveProvider(appAttestTestModel, pr) != p {
				t.Fatal("reserve")
			}
			_, err := p.WriteInferenceTextDeferred(context.Background(), pr, func(time.Time) ([]byte, error) { return []byte("old sealed request"), nil }, func(production.TextFrameWriteMetadata) {
				switch changed {
				case "endpoint":
					p.Mu().Lock()
					p.PublicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
					lease.Endpoint = p.PublicKey
					p.Mu().Unlock()
				case "account":
					p.Mu().Lock()
					p.AccountID = "replacement-account"
					p.Mu().Unlock()
					lease.AccountID = "replacement-account"
				case "machine":
					lease.MachineID = "replacement-machine"
				}
				if !r.BindVerifiedMachineIdentity(p, lease.AccountID, lease.MachineID) || !r.GrantAppAttestServingAuthorization(p, lease) {
					t.Fatal("replacement lease should be valid for future requests")
				}
			})
			if !errors.Is(err, production.ErrProviderServingUnauthorized) || frames.Load() != 0 {
				t.Fatalf("old request transferred: err=%v frames=%d", err, frames.Load())
			}
		})
	}
}

func TestAppAttestFinalHandoffExpiresWhileWaitingForProviderLock(t *testing.T) {
	w := newWriterFixture(8, 8, nil, nil, func([]byte) error { return nil }, nil)
	t.Cleanup(w.Close)
	r, p, lease := appAttestTestProvider(t, production.NewWithDependencies(testLogger(), production.Dependencies{
		Connections: retainedWriterFactory{writer: w.Writer},
	}))
	lease.ValidUntil = time.Now().Add(50 * time.Millisecond)
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant")
	}
	go w.Run()
	pr := &production.PendingRequest{RequestID: "lock-expiry", Model: appAttestTestModel}
	if r.ReserveProvider(appAttestTestModel, pr) != p {
		t.Fatal("reserve")
	}
	handoff := p.NewInferenceHandoff(pr)
	p.Mu().Lock()
	started, done := make(chan struct{}), make(chan error, 1)
	go func() { close(started); done <- handoff.Authorize() }()
	<-started
	<-time.After(time.Until(lease.ValidUntil))
	p.Mu().Unlock()
	select {
	case err := <-done:
		if !errors.Is(err, production.ErrProviderServingUnauthorized) {
			t.Fatalf("expired handoff = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("handoff blocked")
	}
}
