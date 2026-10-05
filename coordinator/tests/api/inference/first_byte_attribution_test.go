package inference_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/backend"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestServingSlotAttributionDoesNotWaitForRegistryLock(t *testing.T) {
	for _, backupOnly := range []bool{false, true} {
		name := "primary"
		if backupOnly {
			name = "backup after primary failure"
		}
		t.Run(name, func(t *testing.T) {
			deps, contention := newAttributionWriteContention()
			srv, _, _ := billingTestServer(t, deps)
			const model = "attribution-lock-model"
			paged := registry.KVBackendPaged
			provider := registerHeartbeatedProvider(t, srv, "attribution-lock-provider", model, &paged)
			pending := &registry.PendingRequest{ProviderID: provider.ID, Model: model}
			latch := srv.NewBackendLatch()
			selectedProvider, selectedPending := provider, pending
			if backupOnly {
				// The failed primary has been cleared; only the backup wait's
				// captured provider and pending request remain available.
				selectedProvider, selectedPending = nil, nil
			}

			// Dispatch already owns this provider. A registry writer must not
			// delay attribution between request handoff and consuming content.
			release := contention.hold(t, srv.registry)
			var slot backend.Slot
			done := make(chan struct{})
			go func() {
				if backupOnly {
					slot = latch.Note(provider, pending, false)
				} else {
					slot = latch.Note(selectedProvider, selectedPending, false)
				}
				close(done)
			}()
			blocked := false
			select {
			case <-done:
			case <-time.After(time.Second):
				blocked = true
			}
			release()
			<-done
			if blocked {
				t.Fatal("serving-slot attribution waited on the registry lock")
			}
			if !slot.Matches(provider.ID, model) || slot.Attribution().Backend != paged {
				t.Fatalf("wrong serving-slot attribution: %+v", slot)
			}
		})
	}
}

type attributionWriteContention struct {
	warmplan.LoadLifecycle
	entered chan struct{}
	release chan struct{}
}

func newAttributionWriteContention() (registry.Dependencies, *attributionWriteContention) {
	c := &attributionWriteContention{
		LoadLifecycle: new(warmplan.LoadState), entered: make(chan struct{}), release: make(chan struct{}),
	}
	return registry.Dependencies{WarmLifecycle: func(id string) warmplan.LoadLifecycle {
		if id == "attribution-contention-aux" {
			return c
		}
		return new(warmplan.LoadState)
	}}, c
}

func (c *attributionWriteContention) Reset() {
	close(c.entered)
	<-c.release
	c.LoadLifecycle.Reset()
}

func (c *attributionWriteContention) hold(t *testing.T, reg *registry.Registry) func() {
	t.Helper()
	reg.Register("attribution-contention-aux", nil, &protocol.RegisterMessage{})
	done := make(chan struct{})
	go func() {
		reg.Disconnect("attribution-contention-aux")
		close(done)
	}()
	<-c.entered
	return func() {
		close(c.release)
		<-done
	}
}
