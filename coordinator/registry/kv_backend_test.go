package registry

import (
	"fmt"
	"strings"
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

// kvSlotDegraded is a slot that resolved to `backend` because paged FELL BACK,
// carrying the provider's reason.
func kvSlotDegraded(model, backend, reason string) protocol.BackendSlotCapacity {
	return protocol.BackendSlotCapacity{
		Model:                   model,
		State:                   "running",
		KVBackend:               &backend,
		KVBackendFallbackReason: &reason,
	}
}

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

// The ticket in one test: two slots serving `contiguous`, one by choice and one
// because it was configured paged and paged did not happen. Before the fallback
// reason they were the same observation. BOTH halves are asserted — a field
// that is always present is not a signal, so the clean slot reporting `none`
// matters exactly as much as the degraded one reporting its class.
func TestSlotKVBackendFallbackSeparatesChoiceFromDegrade(t *testing.T) {
	r := New(testLogger())
	const model = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	chose := registerKVProvider(t, r, "box-chose-contiguous")
	fell := registerKVProvider(t, r, "box-degraded-to-contiguous")
	legacy := registerKVProvider(t, r, "box-pre-080")

	r.Heartbeat(chose, kvHeartbeat(kvSlot(model, kvStr(KVBackendContiguous))))
	r.Heartbeat(fell, kvHeartbeat(kvSlotDegraded(
		model, KVBackendContiguous, "kernel_preflight: paged kernels unavailable")))
	r.Heartbeat(legacy, kvHeartbeat(kvSlot(model, nil)))

	// The resolved kind CANNOT tell the first two apart. That is the defect.
	if r.SlotKVBackendTag(chose, model) != r.SlotKVBackendTag(fell, model) {
		t.Fatalf("premise broken: the two slots should agree on the resolved kind")
	}

	// The fallback dimension can.
	chooseReason, chooseObserved := r.SlotKVBackendFallback(chose, model)
	if !chooseObserved {
		t.Fatal("a slot that named a backend must count as observed")
	}
	if chooseReason != "" {
		t.Errorf("deliberate contiguous reported reason %q, want none", chooseReason)
	}
	fellReason, fellObserved := r.SlotKVBackendFallback(fell, model)
	if !fellObserved || fellReason != "kernel_preflight: paged kernels unavailable" {
		t.Errorf("degraded slot = (%q, %v), want the verbatim reason", fellReason, fellObserved)
	}

	// Tags: `none` and the class are different populations, and the legacy
	// provider is neither — absence of the reason on a slot that never named a
	// backend is UNKNOWN, not "did not degrade".
	for _, tc := range []struct {
		id           string
		wantBackend  string
		wantFallback string
	}{
		{chose, KVBackendContiguous, KVFallbackNone},
		{fell, KVBackendContiguous, KVFallbackKernelPreflight},
		{legacy, KVBackendUnknown, KVFallbackUnknown},
	} {
		backend, fallback := r.SlotKVBackendTags(tc.id, model)
		if backend != tc.wantBackend || fallback != tc.wantFallback {
			t.Errorf("%s = (%q, %q), want (%q, %q)",
				tc.id, backend, fallback, tc.wantBackend, tc.wantFallback)
		}
	}
}

// The kind and the reason are ONE observation. A slot that degrades, is
// reloaded and comes back clean must stop reporting the degrade — a reason that
// only ever gets written is a permanent false positive on a healthy slot.
func TestSlotKVBackendFallbackClearsOnACleanReload(t *testing.T) {
	r := New(testLogger())
	id := registerKVProvider(t, r, "box-reloading")
	const model = "gemma"

	r.Heartbeat(id, kvHeartbeat(kvSlotDegraded(model, KVBackendContiguous, "kill_switch")))
	if _, fallback := r.SlotKVBackendTags(id, model); fallback != KVFallbackKillSwitch {
		t.Fatalf("degraded slot = %q, want %q", fallback, KVFallbackKillSwitch)
	}

	// Operator clears the kill switch and the slot reloads onto paged.
	r.Heartbeat(id, kvHeartbeat(kvSlot(model, kvStr(KVBackendPaged))))
	backend, fallback := r.SlotKVBackendTags(id, model)
	if backend != KVBackendPaged {
		t.Errorf("reloaded kind = %q, want %q", backend, KVBackendPaged)
	}
	if fallback != KVFallbackNone {
		t.Errorf("reloaded fallback = %q, want %q — the stale degrade was never cleared",
			fallback, KVFallbackNone)
	}

	// A heartbeat that names no backend at all leaves BOTH halves alone, so a
	// slot torn down mid-request keeps its attribution.
	r.Heartbeat(id, kvHeartbeat())
	if backend, fallback := r.SlotKVBackendTags(id, model); backend != KVBackendPaged || fallback != KVFallbackNone {
		t.Errorf("after the slot vanished = (%q, %q), want (%q, %q)",
			backend, fallback, KVBackendPaged, KVFallbackNone)
	}
}

// The reason is untrusted free text that becomes a metric tag, so it is folded
// onto a bounded class vocabulary and clamped in storage.
func TestKVBackendFallbackTagVocabulary(t *testing.T) {
	for _, tc := range []struct {
		reason   string
		observed bool
		want     string
	}{
		// The five shipped producer classes, with and without detail.
		{"kill_switch", true, KVFallbackKillSwitch},
		{"kernel_preflight: MTLLibrary compile failed", true, KVFallbackKernelPreflight},
		{"physical_capacity: unknown KV byte rate", true, KVFallbackPhysicalCapacity},
		{"ineligible: sliding-window layout", true, KVFallbackIneligible},
		{"pool_construction_capacity: needed 3, available 1", true, KVFallbackPoolConstruction},
		// Observed with no reason is the authoritative "did not degrade".
		{"", true, KVFallbackNone},
		// Unobserved says nothing at all — never `none`.
		{"", false, KVFallbackUnknown},
		{"kill_switch", false, KVFallbackUnknown},
		// Cardinality fence: a future or malformed class is bucketed, and the
		// unbounded detail never reaches the tag.
		{"quantum_flux: 12345", true, KVFallbackOther},
		{"needed 3221225472 bytes", true, KVFallbackOther},
	} {
		if got := KVBackendFallbackTag(tc.reason, tc.observed); got != tc.want {
			t.Errorf("KVBackendFallbackTag(%q, %v) = %q, want %q",
				tc.reason, tc.observed, got, tc.want)
		}
	}
}

// A hostile or future provider must not park an unbounded string in coordinator
// state for the life of the session, but the class must still survive.
func TestSlotKVBackendFallbackReasonIsClamped(t *testing.T) {
	r := New(testLogger())
	id := registerKVProvider(t, r, "box-verbose")
	const model = "gemma"

	long := "ineligible: " + strings.Repeat("x", maxKVFallbackReasonBytes*4)
	r.Heartbeat(id, kvHeartbeat(kvSlotDegraded(model, KVBackendContiguous, long)))

	stored, observed := r.SlotKVBackendFallback(id, model)
	if !observed {
		t.Fatal("slot not observed")
	}
	if len(stored) != maxKVFallbackReasonBytes {
		t.Errorf("stored %d bytes, want the clamp %d", len(stored), maxKVFallbackReasonBytes)
	}
	// Truncation is from the tail: the leading class the metric groups on is
	// exactly what must survive.
	if _, fallback := r.SlotKVBackendTags(id, model); fallback != KVFallbackIneligible {
		t.Errorf("clamped reason tagged %q, want %q", fallback, KVFallbackIneligible)
	}
}

// A slot that names no backend contributes nothing, even if it somehow carries
// a reason: the pair is gated on the kind, so a reason alone cannot manufacture
// an observation out of a provider that reported no backend.
func TestSlotKVBackendFallbackIgnoredWithoutAKind(t *testing.T) {
	r := New(testLogger())
	id := registerKVProvider(t, r, "box-reason-only")
	const model = "gemma"

	reason := "kill_switch"
	r.Heartbeat(id, kvHeartbeat(protocol.BackendSlotCapacity{
		Model: model, State: "running", KVBackendFallbackReason: &reason,
	}))
	backend, fallback := r.SlotKVBackendTags(id, model)
	if backend != KVBackendUnknown || fallback != KVFallbackUnknown {
		t.Errorf("reason without a kind = (%q, %q), want both unknown", backend, fallback)
	}
}
