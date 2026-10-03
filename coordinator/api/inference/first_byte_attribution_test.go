package inference

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestServingSlotAttributionDoesNotWaitForRegistryLock(t *testing.T) {
	for _, backupOnly := range []bool{false, true} {
		name := "primary"
		if backupOnly {
			name = "backup after primary failure"
		}
		t.Run(name, func(t *testing.T) {
			srv, _, _ := billingTestServer(t)
			const model = "attribution-lock-model"
			paged := registry.KVBackendPaged
			provider := registerHeartbeatedProvider(t, srv, "attribution-lock-provider", model, &paged)
			pending := &registry.PendingRequest{ProviderID: provider.ID, Model: model}
			d := &dispatchState{s: srv, provider: provider, pr: pending}
			if backupOnly {
				// The failed primary has been cleared; only the backup wait's
				// captured provider and pending request remain available.
				d.provider, d.pr = nil, nil
			}

			// Dispatch already owns this provider. A registry writer must not
			// delay attribution between request handoff and consuming content.
			release := srv.registry.HoldWriteLockForTest()
			done := make(chan struct{})
			go func() {
				if backupOnly {
					d.noteServingSlotFor(provider, pending)
				} else {
					d.noteServingSlot()
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
			if d.servedKVSlot.providerID != provider.ID || d.servedKVSlot.backend.Backend != paged {
				t.Fatalf("wrong serving-slot attribution: %+v", d.servedKVSlot)
			}
		})
	}
}
