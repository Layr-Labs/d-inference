package dispatch

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TestDispatchKVBackendTagFollowsTheServingSlot pins the two behaviours of the
// dispatch-side resolver: the latch survives a failover clearing d.pr (the
// exhaustion ladder still attributes the failure), and a live d.pr WINS over
// the latch (a speculative backup that takes over is attributed to the backup's
// slot, not the primary's).
func TestDispatchKVBackendTagFollowsTheServingSlot(t *testing.T) {
	srv := newTestController(t)
	const model = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	paged, contiguous := registry.KVBackendPaged, registry.KVBackendContiguous
	primary := registerHeartbeatedProvider(t, srv, "g5-latch-primary", model, &paged)
	backup := registerHeartbeatedProvider(t, srv, "g5-latch-backup", model, &contiguous)

	d := &execution{s: srv, model: model}
	// Never reached a slot yet.
	if got := d.KVBackendAttribution().Backend; got != registry.KVBackendUnknown {
		t.Fatalf("before dispatch = %q, want %q", got, registry.KVBackendUnknown)
	}

	d.pr = &registry.PendingRequest{RequestID: "req-latch", ProviderID: primary.ID, Model: model}
	d.noteServingSlot()
	d.pr = nil
	if got := d.KVBackendAttribution().Backend; got != registry.KVBackendPaged {
		t.Errorf("after failover cleared d.pr = %q, want %q (the latch is what keeps a crashed "+
			"paged slot's 5xx attributable)", got, registry.KVBackendPaged)
	}

	// Speculative backup takes over: the live pending request wins.
	d.pr = &registry.PendingRequest{RequestID: "req-latch-backup", ProviderID: backup.ID, Model: model}
	if got := d.KVBackendAttribution().Backend; got != registry.KVBackendContiguous {
		t.Errorf("after a backup win = %q, want %q", got, registry.KVBackendContiguous)
	}
}
