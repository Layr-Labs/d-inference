package registry

import (
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Gate G5: the coordinator must be able to segment by KV backend, which means
// the heartbeat's per-slot `kv_backend` has to survive ingest as a TRI-STATE —
// paged | contiguous | unknown-because-absent. These tests drive the REAL
// heartbeat path (Registry.Heartbeat), not a hand-set Provider field, so a
// change that stops recording the value fails here.

func kvSlot(model string, backend *string) protocol.BackendSlotCapacity {
	return protocol.BackendSlotCapacity{Model: model, State: "running", KVBackend: backend}
}

func kvHeartbeat(slots ...protocol.BackendSlotCapacity) *protocol.HeartbeatMessage {
	return &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "serving",
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots:         slots,
		},
	}
}

func kvStr(s string) *string { return &s }

// registerKVProvider registers a provider under a deterministic id and returns
// that id.
func registerKVProvider(t *testing.T, r *Registry, id string) string {
	t.Helper()
	r.Register(id, nil, testRegisterMessage())
	if r.GetProvider(id) == nil {
		t.Fatalf("provider %q did not register", id)
	}
	return id
}

// A mixed fleet — paged, contiguous, and a pre-0.8.0 provider that omits the
// key — must resolve to three distinct populations. The load-bearing assertion
// is the LAST one: an absent value must never book as contiguous. If it did,
// the rollout dashboard would show a clean contiguous baseline composed
// entirely of legacy providers, which is the exact failure the *string exists
// to prevent.
func TestSlotKVBackendMixedFleetSeparatesThreePopulations(t *testing.T) {
	r := New(testLogger())
	const model = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"

	paged := registerKVProvider(t, r, "box-paged")
	contiguous := registerKVProvider(t, r, "box-contiguous")
	legacy := registerKVProvider(t, r, "box-pre-080")

	r.Heartbeat(paged, kvHeartbeat(kvSlot(model, kvStr(KVBackendPaged))))
	r.Heartbeat(contiguous, kvHeartbeat(kvSlot(model, kvStr(KVBackendContiguous))))
	// Exactly the pre-0.8.0 wire shape: the slot is reported, kv_backend is not.
	r.Heartbeat(legacy, kvHeartbeat(kvSlot(model, nil)))

	for _, tc := range []struct {
		providerID string
		wantKind   string
		wantSeen   bool
		wantTag    string
	}{
		{paged, KVBackendPaged, true, KVBackendPaged},
		{contiguous, KVBackendContiguous, true, KVBackendContiguous},
		{legacy, "", false, KVBackendUnknown},
	} {
		kind, observed := r.SlotKVBackend(tc.providerID, model)
		if kind != tc.wantKind || observed != tc.wantSeen {
			t.Errorf("SlotKVBackend(%s) = (%q, %v), want (%q, %v)",
				tc.providerID, kind, observed, tc.wantKind, tc.wantSeen)
		}
		if got := r.SlotKVBackendTag(tc.providerID, model); got != tc.wantTag {
			t.Errorf("SlotKVBackendTag(%s) = %q, want %q", tc.providerID, got, tc.wantTag)
		}
	}

	// No silent defaulting, stated as its own assertion so the intent survives a
	// refactor of the table above.
	legacyTag := r.SlotKVBackendTag(legacy, model)
	if legacyTag == KVBackendContiguous {
		t.Fatal("absent kv_backend booked as contiguous — a pre-0.8.0 provider would forge a contiguous sample")
	}
	if legacyTag == KVBackendPaged {
		t.Fatal("absent kv_backend booked as paged")
	}
}

// One box, two models, two backends. A staged rollout legitimately produces
// this, and attributing at provider granularity would blend the two
// populations the gate exists to separate.
func TestSlotKVBackendIsPerSlotNotPerProvider(t *testing.T) {
	r := New(testLogger())
	id := registerKVProvider(t, r, "box-mixed-slots")
	const pagedModel = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	const contiguousModel = "mlx-community/gpt-oss-20b"

	r.Heartbeat(id, kvHeartbeat(
		kvSlot(pagedModel, kvStr(KVBackendPaged)),
		kvSlot(contiguousModel, kvStr(KVBackendContiguous)),
	))

	if got := r.SlotKVBackendTag(id, pagedModel); got != KVBackendPaged {
		t.Errorf("paged slot on a mixed box = %q, want %q", got, KVBackendPaged)
	}
	if got := r.SlotKVBackendTag(id, contiguousModel); got != KVBackendContiguous {
		t.Errorf("contiguous slot on a mixed box = %q, want %q", got, KVBackendContiguous)
	}
	// A model the box never loaded is unknown, not the other slot's backend.
	if got := r.SlotKVBackendTag(id, "mlx-community/never-loaded"); got != KVBackendUnknown {
		t.Errorf("unseen slot on a known provider = %q, want %q", got, KVBackendUnknown)
	}
}

// A non-nil pointer to "" is an authoritative "slot present, backend
// unnameable" and marshals as `"kv_backend":""`. It must stay distinguishable
// from omission on this side too, or the pointer type on the wire buys nothing.
func TestSlotKVBackendExplicitEmptyStaysDistinctFromAbsent(t *testing.T) {
	r := New(testLogger())
	const model = "qwen"
	explicit := registerKVProvider(t, r, "box-explicit-empty")
	absent := registerKVProvider(t, r, "box-absent")

	r.Heartbeat(explicit, kvHeartbeat(kvSlot(model, kvStr(""))))
	r.Heartbeat(absent, kvHeartbeat(kvSlot(model, nil)))

	kind, observed := r.SlotKVBackend(explicit, model)
	if kind != "" || !observed {
		t.Fatalf("explicit empty = (%q, %v), want (\"\", true)", kind, observed)
	}
	if got := r.SlotKVBackendTag(explicit, model); got != KVBackendUnspecified {
		t.Errorf("explicit empty tag = %q, want %q", got, KVBackendUnspecified)
	}
	if got := r.SlotKVBackendTag(absent, model); got != KVBackendUnknown {
		t.Errorf("absent tag = %q, want %q", got, KVBackendUnknown)
	}
	if r.SlotKVBackendTag(explicit, model) == r.SlotKVBackendTag(absent, model) {
		t.Fatal("explicit-empty and absent collapsed to the same tag; they are not the same observation")
	}
}

// The provider only reports RESIDENT engine slots, so a slot that crashes,
// OOMs or is evicted vanishes from the next heartbeat. An in-flight request on
// that slot still has to be attributable — a paged slot falling over is the
// single most interesting sample in the rollout.
func TestSlotKVBackendSurvivesSlotLeavingTheHeartbeat(t *testing.T) {
	r := New(testLogger())
	id := registerKVProvider(t, r, "box-evicting")
	const model = "gemma"

	r.Heartbeat(id, kvHeartbeat(kvSlot(model, kvStr(KVBackendPaged))))
	// Slot gone: the model was evicted / the engine crashed.
	r.Heartbeat(id, kvHeartbeat())
	if got := r.SlotKVBackendTag(id, model); got != KVBackendPaged {
		t.Errorf("after the slot vanished = %q, want %q (attribution must survive slot teardown)", got, KVBackendPaged)
	}

	// A nil BackendCapacity clears live routing state but must not erase the
	// attribution record either.
	r.Heartbeat(id, &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: "idle"})
	if got := r.SlotKVBackendTag(id, model); got != KVBackendPaged {
		t.Errorf("after a capacity-less heartbeat = %q, want %q", got, KVBackendPaged)
	}

	// A later heartbeat that DOES name a backend wins: a reload onto the other
	// backend must not keep reporting the stale kind.
	r.Heartbeat(id, kvHeartbeat(kvSlot(model, kvStr(KVBackendContiguous))))
	if got := r.SlotKVBackendTag(id, model); got != KVBackendContiguous {
		t.Errorf("after a re-load onto contiguous = %q, want %q", got, KVBackendContiguous)
	}
}

// The value is untrusted provider input and becomes a metric tag, so an
// unrecognized kind must be fenced into a single bucket rather than minting a
// new tag value per request.
func TestSlotKVBackendUnknownKindFencedToOther(t *testing.T) {
	r := New(testLogger())
	id := registerKVProvider(t, r, "box-future")
	const model = "gemma"

	r.Heartbeat(id, kvHeartbeat(kvSlot(model, kvStr("paged_quantized"))))
	kind, observed := r.SlotKVBackend(id, model)
	if kind != "paged_quantized" || !observed {
		t.Fatalf("state must stay faithful to the wire: got (%q, %v)", kind, observed)
	}
	if got := r.SlotKVBackendTag(id, model); got != KVBackendOther {
		t.Errorf("unrecognized kind tag = %q, want %q", got, KVBackendOther)
	}
}

// A provider that heartbeats an unbounded number of distinct slot models must
// not grow coordinator state without bound.
func TestSlotKVBackendRecordIsBounded(t *testing.T) {
	r := New(testLogger())
	id := registerKVProvider(t, r, "box-flood")

	slots := make([]protocol.BackendSlotCapacity, 0, maxTrackedKVBackendSlots*2)
	for i := range maxTrackedKVBackendSlots * 2 {
		slots = append(slots, kvSlot(fmt.Sprintf("model-%d", i), kvStr(KVBackendPaged)))
	}
	r.Heartbeat(id, kvHeartbeat(slots...))

	p := r.GetProvider(id)
	p.mu.Lock()
	tracked := len(p.kvBackends)
	p.mu.Unlock()
	if tracked != maxTrackedKVBackendSlots {
		t.Fatalf("tracked %d slot models, want the cap %d", tracked, maxTrackedKVBackendSlots)
	}
	// Past the cap, a model is unattributed — never mis-attributed.
	if got := r.SlotKVBackendTag(id, fmt.Sprintf("model-%d", maxTrackedKVBackendSlots*2-1)); got != KVBackendUnknown {
		t.Errorf("model past the cap = %q, want %q", got, KVBackendUnknown)
	}
	// Slots recorded before the cap keep reporting normally, and a repeat
	// heartbeat refreshes them rather than being refused as "new".
	r.Heartbeat(id, kvHeartbeat(kvSlot("model-0", kvStr(KVBackendContiguous))))
	if got := r.SlotKVBackendTag(id, "model-0"); got != KVBackendContiguous {
		t.Errorf("already-tracked model refresh = %q, want %q", got, KVBackendContiguous)
	}
}

func TestKVBackendTagVocabulary(t *testing.T) {
	for _, tc := range []struct {
		kind     string
		observed bool
		want     string
	}{
		{KVBackendPaged, true, KVBackendPaged},
		{KVBackendContiguous, true, KVBackendContiguous},
		{"", true, KVBackendUnspecified},
		{"something_else", true, KVBackendOther},
		{"", false, KVBackendUnknown},
		// An unobserved slot is unknown even if a kind somehow rode along.
		{KVBackendPaged, false, KVBackendUnknown},
	} {
		if got := KVBackendTag(tc.kind, tc.observed); got != tc.want {
			t.Errorf("KVBackendTag(%q, %v) = %q, want %q", tc.kind, tc.observed, got, tc.want)
		}
	}
}

// Lookups that cannot name a slot must answer "unknown" rather than panic or
// guess: an unknown provider id (disconnected mid-request) and empty inputs.
func TestSlotKVBackendUnknownProviderIsUnknown(t *testing.T) {
	r := New(testLogger())
	if got := r.SlotKVBackendTag("no-such-provider", "gemma"); got != KVBackendUnknown {
		t.Errorf("unknown provider = %q, want %q", got, KVBackendUnknown)
	}
	if got := r.SlotKVBackendTag("", ""); got != KVBackendUnknown {
		t.Errorf("empty ids = %q, want %q", got, KVBackendUnknown)
	}
}
