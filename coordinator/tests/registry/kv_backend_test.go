package registry_test

import (
	"fmt"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/kvbackend"
	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// Gate G5: the coordinator must be able to segment by KV backend, which means
// the heartbeat's per-slot `kv_backend` has to survive ingest as a TRI-STATE —
// paged | contiguous | unknown-because-absent. These tests drive the REAL
// heartbeat path (Registry.Heartbeat), not a hand-set Provider field, so a
// change that stops recording the value fails here.

const (
	maxTrackedKVBackendSlots = kvbackend.MaxTrackedSlots
	maxKVFallbackReasonBytes = kvbackend.MaxFallbackReasonBytes
)

func newKVBackendRegistry() (*production.Registry, map[string]*kvbackend.History) {
	histories := make(map[string]*kvbackend.History)
	r := production.NewWithDependencies(testLogger(), production.Dependencies{
		KVBackends: func(id string) *kvbackend.History {
			history := &kvbackend.History{}
			histories[id] = history
			return history
		},
	})
	return r, histories
}

// Observe the retained production history under the same provider lock used by
// heartbeat ingestion and metric tagging, without exporting raw root getters.
func observeKVBackend(r *production.Registry, histories map[string]*kvbackend.History, id, model string) (kvbackend.Observation, bool) {
	p := r.GetProvider(id)
	p.Mu().Lock()
	defer p.Mu().Unlock()
	return histories[id].Observe(model)
}

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

func slotKVBackendTag(r *production.Registry, providerID, model string) string {
	backend, _ := r.SlotKVBackendTags(providerID, model)
	return backend
}

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
func registerKVProvider(t *testing.T, r *production.Registry, id string, models ...string) string {
	t.Helper()
	msg := testRegisterMessage()
	if len(models) > 0 {
		msg.Models = make([]protocol.ModelInfo, 0, len(models))
		for _, modelID := range models {
			msg.Models = append(msg.Models, protocol.ModelInfo{ID: modelID})
		}
	}
	r.Register(id, nil, msg)
	if r.GetProvider(id) == nil {
		t.Fatalf("provider %q did not register", id)
	}
	return id
}

// One box, two models, two backends. A staged rollout legitimately produces
// this, and attributing at provider granularity would blend the two
// populations the gate exists to separate.
func TestSlotKVBackendIsPerSlotNotPerProvider(t *testing.T) {
	r := production.New(testLogger())
	const pagedModel = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	const contiguousModel = "mlx-community/gpt-oss-20b"
	id := registerKVProvider(t, r, "box-mixed-slots", pagedModel, contiguousModel)

	r.Heartbeat(id, kvHeartbeat(
		kvSlot(pagedModel, kvStr(production.KVBackendPaged)),
		kvSlot(contiguousModel, kvStr(production.KVBackendContiguous)),
	))

	if got := slotKVBackendTag(r, id, pagedModel); got != production.KVBackendPaged {
		t.Errorf("paged slot on a mixed box = %q, want %q", got, production.KVBackendPaged)
	}
	if got := slotKVBackendTag(r, id, contiguousModel); got != production.KVBackendContiguous {
		t.Errorf("contiguous slot on a mixed box = %q, want %q", got, production.KVBackendContiguous)
	}
	// A model the box never loaded is unknown, not the other slot's backend.
	if got := slotKVBackendTag(r, id, "mlx-community/never-loaded"); got != production.KVBackendUnknown {
		t.Errorf("unseen slot on a known provider = %q, want %q", got, production.KVBackendUnknown)
	}
}

// The provider only reports RESIDENT engine slots, so a slot that crashes,
// OOMs or is evicted vanishes from the next heartbeat. An in-flight request on
// that slot still has to be attributable — a paged slot falling over is the
// single most interesting sample in the rollout.
func TestSlotKVBackendSurvivesSlotLeavingTheHeartbeat(t *testing.T) {
	r := production.New(testLogger())
	const model = "gemma"
	id := registerKVProvider(t, r, "box-evicting", model)

	r.Heartbeat(id, kvHeartbeat(kvSlot(model, kvStr(production.KVBackendPaged))))
	// Slot gone: the model was evicted / the engine crashed.
	r.Heartbeat(id, kvHeartbeat())
	if got := slotKVBackendTag(r, id, model); got != production.KVBackendPaged {
		t.Errorf("after the slot vanished = %q, want %q (attribution must survive slot teardown)", got, production.KVBackendPaged)
	}

	// A nil BackendCapacity clears live routing state but must not erase the
	// attribution record either.
	r.Heartbeat(id, &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: "idle"})
	if got := slotKVBackendTag(r, id, model); got != production.KVBackendPaged {
		t.Errorf("after a capacity-less heartbeat = %q, want %q", got, production.KVBackendPaged)
	}

	// A later heartbeat that DOES name a backend wins: a reload onto the other
	// backend must not keep reporting the stale kind.
	r.Heartbeat(id, kvHeartbeat(kvSlot(model, kvStr(production.KVBackendContiguous))))
	if got := slotKVBackendTag(r, id, model); got != production.KVBackendContiguous {
		t.Errorf("after a re-load onto contiguous = %q, want %q", got, production.KVBackendContiguous)
	}
}

func TestKVBackendTagVocabulary(t *testing.T) {
	for _, tc := range []struct {
		kind     string
		observed bool
		want     string
	}{
		{production.KVBackendPaged, true, production.KVBackendPaged},
		{production.KVBackendContiguous, true, production.KVBackendContiguous},
		{"", true, production.KVBackendUnspecified},
		{"something_else", true, production.KVBackendOther},
		{"", false, production.KVBackendUnknown},
		// An unobserved slot is unknown even if a kind somehow rode along.
		{production.KVBackendPaged, false, production.KVBackendUnknown},
	} {
		if got := production.KVBackendTag(tc.kind, tc.observed); got != tc.want {
			t.Errorf("KVBackendTag(%q, %v) = %q, want %q", tc.kind, tc.observed, got, tc.want)
		}
	}
}

// Lookups that cannot name a slot must answer "unknown" rather than panic or
// guess: an unknown provider id (disconnected mid-request) and empty inputs.
func TestSlotKVBackendUnknownProviderIsUnknown(t *testing.T) {
	r := production.New(testLogger())
	if got := slotKVBackendTag(r, "no-such-provider", "gemma"); got != production.KVBackendUnknown {
		t.Errorf("unknown provider = %q, want %q", got, production.KVBackendUnknown)
	}
	if got := slotKVBackendTag(r, "", ""); got != production.KVBackendUnknown {
		t.Errorf("empty ids = %q, want %q", got, production.KVBackendUnknown)
	}
	// Nil receivers: the API layer resolves attribution off a provider it
	// already holds, and a nil registry is the in-memory/test shape.
	var nilProvider *production.Provider
	if backend, fallback := nilProvider.SlotKVBackendTags("gemma"); backend != production.KVBackendUnknown ||
		fallback != production.KVFallbackUnknown {
		t.Errorf("nil provider = (%q, %q), want both unknown", backend, fallback)
	}
	var nilRegistry *production.Registry
	if backend, fallback := nilRegistry.SlotKVBackendTags("p", "gemma"); backend != production.KVBackendUnknown ||
		fallback != production.KVFallbackUnknown {
		t.Errorf("nil registry = (%q, %q), want both unknown", backend, fallback)
	}
}

// The kind and the reason are ONE observation. A slot that degrades, is
// reloaded and comes back clean must stop reporting the degrade — a reason that
// only ever gets written is a permanent false positive on a healthy slot.
func TestSlotKVBackendFallbackClearsOnACleanReload(t *testing.T) {
	r := production.New(testLogger())
	const model = "gemma"
	id := registerKVProvider(t, r, "box-reloading", model)

	r.Heartbeat(id, kvHeartbeat(kvSlotDegraded(model, production.KVBackendContiguous, "kill_switch")))
	if _, fallback := r.SlotKVBackendTags(id, model); fallback != production.KVFallbackKillSwitch {
		t.Fatalf("degraded slot = %q, want %q", fallback, production.KVFallbackKillSwitch)
	}

	// Operator clears the kill switch and the slot reloads onto paged.
	r.Heartbeat(id, kvHeartbeat(kvSlot(model, kvStr(production.KVBackendPaged))))
	backend, fallback := r.SlotKVBackendTags(id, model)
	if backend != production.KVBackendPaged {
		t.Errorf("reloaded kind = %q, want %q", backend, production.KVBackendPaged)
	}
	if fallback != production.KVFallbackNone {
		t.Errorf("reloaded fallback = %q, want %q — the stale degrade was never cleared",
			fallback, production.KVFallbackNone)
	}

	// A heartbeat that names no backend at all leaves BOTH halves alone, so a
	// slot torn down mid-request keeps its attribution.
	r.Heartbeat(id, kvHeartbeat())
	if backend, fallback := r.SlotKVBackendTags(id, model); backend != production.KVBackendPaged || fallback != production.KVFallbackNone {
		t.Errorf("after the slot vanished = (%q, %q), want (%q, %q)",
			backend, fallback, production.KVBackendPaged, production.KVFallbackNone)
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
		// The seven shipped producer classes, with and without detail.
		{"kill_switch", true, production.KVFallbackKillSwitch},
		// The watchdog's crash-loop guard (bare, like kill_switch — the
		// detail lives in the guard record and the trip event, not here).
		{"crash_loop_guard", true, production.KVFallbackCrashLoopGuard},
		{"kernel_preflight: MTLLibrary compile failed", true, production.KVFallbackKernelPreflight},
		{"physical_capacity: unknown KV byte rate", true, production.KVFallbackPhysicalCapacity},
		{"ineligible: sliding-window layout", true, production.KVFallbackIneligible},
		{"pool_construction_capacity: needed 3, available 1", true, production.KVFallbackPoolConstruction},
		// The `.auto` dtype degrade carries the typo verbatim in the tail;
		// only the class token reaches the tag.
		{"invalid_dtype: fp32", true, production.KVFallbackInvalidDType},
		// Observed with no reason is the authoritative "did not degrade".
		{"", true, production.KVFallbackNone},
		// Unobserved says nothing at all — never `none`.
		{"", false, production.KVFallbackUnknown},
		{"kill_switch", false, production.KVFallbackUnknown},
		// Cardinality fence: a future or malformed class is bucketed, and the
		// unbounded detail never reaches the tag.
		{"quantum_flux: 12345", true, production.KVFallbackOther},
		{"needed 3221225472 bytes", true, production.KVFallbackOther},
	} {
		if got := production.KVBackendFallbackTag(tc.reason, tc.observed); got != tc.want {
			t.Errorf("KVBackendFallbackTag(%q, %v) = %q, want %q",
				tc.reason, tc.observed, got, tc.want)
		}
	}
}

// A slot that names no backend contributes nothing, even if it somehow carries
// a reason: the pair is gated on the kind, so a reason alone cannot manufacture
// an observation out of a provider that reported no backend.
func TestSlotKVBackendFallbackIgnoredWithoutAKind(t *testing.T) {
	r := production.New(testLogger())
	const model = "gemma"
	id := registerKVProvider(t, r, "box-reason-only", model)

	reason := "kill_switch"
	r.Heartbeat(id, kvHeartbeat(protocol.BackendSlotCapacity{
		Model: model, State: "running", KVBackendFallbackReason: &reason,
	}))
	backend, fallback := r.SlotKVBackendTags(id, model)
	if backend != production.KVBackendUnknown || fallback != production.KVFallbackUnknown {
		t.Errorf("reason without a kind = (%q, %q), want both unknown", backend, fallback)
	}
}

// A mixed fleet — paged, contiguous, and a pre-0.8.0 provider that omits the
// key — must resolve to three distinct populations. The load-bearing assertion
// is the LAST one: an absent value must never book as contiguous. If it did,
// the rollout dashboard would show a clean contiguous baseline composed
// entirely of legacy providers, which is the exact failure the *string exists
// to prevent.
func TestSlotKVBackendMixedFleetSeparatesThreePopulations(t *testing.T) {
	r, histories := newKVBackendRegistry()
	const model = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"

	paged := registerKVProvider(t, r, "box-paged", model)
	contiguous := registerKVProvider(t, r, "box-contiguous", model)
	legacy := registerKVProvider(t, r, "box-pre-080", model)

	r.Heartbeat(paged, kvHeartbeat(kvSlot(model, kvStr(production.KVBackendPaged))))
	r.Heartbeat(contiguous, kvHeartbeat(kvSlot(model, kvStr(production.KVBackendContiguous))))
	// Exactly the pre-0.8.0 wire shape: the slot is reported, kv_backend is not.
	r.Heartbeat(legacy, kvHeartbeat(kvSlot(model, nil)))

	for _, tc := range []struct {
		providerID string
		wantKind   string
		wantSeen   bool
		wantTag    string
	}{
		{paged, production.KVBackendPaged, true, production.KVBackendPaged},
		{contiguous, production.KVBackendContiguous, true, production.KVBackendContiguous},
		{legacy, "", false, production.KVBackendUnknown},
	} {
		obs, observed := observeKVBackend(r, histories, tc.providerID, model)
		kind := obs.Kind
		if kind != tc.wantKind || observed != tc.wantSeen {
			t.Errorf("SlotKVBackend(%s) = (%q, %v), want (%q, %v)",
				tc.providerID, kind, observed, tc.wantKind, tc.wantSeen)
		}
		if got := slotKVBackendTag(r, tc.providerID, model); got != tc.wantTag {
			t.Errorf("SlotKVBackendTag(%s) = %q, want %q", tc.providerID, got, tc.wantTag)
		}
	}

	// No silent defaulting, stated as its own assertion so the intent survives a
	// refactor of the table above.
	legacyTag := slotKVBackendTag(r, legacy, model)
	if legacyTag == production.KVBackendContiguous {
		t.Fatal("absent kv_backend booked as contiguous — a pre-0.8.0 provider would forge a contiguous sample")
	}
	if legacyTag == production.KVBackendPaged {
		t.Fatal("absent kv_backend booked as paged")
	}
}

// A non-nil pointer to "" is an authoritative "slot present, backend
// unnameable" and marshals as `"kv_backend":""`. It must stay distinguishable
// from omission on this side too, or the pointer type on the wire buys nothing.
func TestSlotKVBackendExplicitEmptyStaysDistinctFromAbsent(t *testing.T) {
	r, histories := newKVBackendRegistry()
	const model = "qwen"
	explicit := registerKVProvider(t, r, "box-explicit-empty", model)
	absent := registerKVProvider(t, r, "box-absent", model)

	r.Heartbeat(explicit, kvHeartbeat(kvSlot(model, kvStr(""))))
	r.Heartbeat(absent, kvHeartbeat(kvSlot(model, nil)))

	obs, observed := observeKVBackend(r, histories, explicit, model)
	kind := obs.Kind
	if kind != "" || !observed {
		t.Fatalf("explicit empty = (%q, %v), want (\"\", true)", kind, observed)
	}
	if got := slotKVBackendTag(r, explicit, model); got != production.KVBackendUnspecified {
		t.Errorf("explicit empty tag = %q, want %q", got, production.KVBackendUnspecified)
	}
	if got := slotKVBackendTag(r, absent, model); got != production.KVBackendUnknown {
		t.Errorf("absent tag = %q, want %q", got, production.KVBackendUnknown)
	}
	if slotKVBackendTag(r, explicit, model) == slotKVBackendTag(r, absent, model) {
		t.Fatal("explicit-empty and absent collapsed to the same tag; they are not the same observation")
	}
}

// The value is untrusted provider input and becomes a metric tag, so an
// unrecognized kind must be fenced into a single bucket rather than minting a
// new tag value per request.
func TestSlotKVBackendUnknownKindFencedToOther(t *testing.T) {
	r, histories := newKVBackendRegistry()
	const model = "gemma"
	id := registerKVProvider(t, r, "box-future", model)

	r.Heartbeat(id, kvHeartbeat(kvSlot(model, kvStr("paged_quantized"))))
	obs, observed := observeKVBackend(r, histories, id, model)
	kind := obs.Kind
	if kind != "paged_quantized" || !observed {
		t.Fatalf("state must stay faithful to the wire: got (%q, %v)", kind, observed)
	}
	if got := slotKVBackendTag(r, id, model); got != production.KVBackendOther {
		t.Errorf("unrecognized kind tag = %q, want %q", got, production.KVBackendOther)
	}
}

// A provider that heartbeats an unbounded number of distinct slot models must
// not grow coordinator state without bound.
func TestSlotKVBackendRecordIsBounded(t *testing.T) {
	r, histories := newKVBackendRegistry()
	slots := make([]protocol.BackendSlotCapacity, 0, maxTrackedKVBackendSlots*2)
	models := make([]string, 0, maxTrackedKVBackendSlots*2)
	for i := range maxTrackedKVBackendSlots * 2 {
		modelID := fmt.Sprintf("model-%d", i)
		models = append(models, modelID)
		slots = append(slots, kvSlot(modelID, kvStr(production.KVBackendPaged)))
	}
	id := registerKVProvider(t, r, "box-flood", models...)
	r.Heartbeat(id, kvHeartbeat(slots...))

	p := r.GetProvider(id)
	p.Mu().Lock()
	tracked := 0
	for _, modelID := range models {
		if _, observed := histories[id].Observe(modelID); observed {
			tracked++
		}
	}
	p.Mu().Unlock()
	if tracked != maxTrackedKVBackendSlots {
		t.Fatalf("tracked %d slot models, want the cap %d", tracked, maxTrackedKVBackendSlots)
	}
	// Past the cap, a model is unattributed — never mis-attributed.
	if got := slotKVBackendTag(r, id, fmt.Sprintf("model-%d", maxTrackedKVBackendSlots*2-1)); got != production.KVBackendUnknown {
		t.Errorf("model past the cap = %q, want %q", got, production.KVBackendUnknown)
	}
	// Slots recorded before the cap keep reporting normally, and a repeat
	// heartbeat refreshes them rather than being refused as "new".
	r.Heartbeat(id, kvHeartbeat(kvSlot("model-0", kvStr(production.KVBackendContiguous))))
	if got := slotKVBackendTag(r, id, "model-0"); got != production.KVBackendContiguous {
		t.Errorf("already-tracked model refresh = %q, want %q", got, production.KVBackendContiguous)
	}
}

// The API layer emits these values as metric tags WITHOUT re-normalizing, so
// the guarantee has to hold here: neither producer can return "". An empty tag
// renders as a bare `kv_backend:` on the dashboard and silently pools with
// nothing. Exhaustive over the tri-state input space rather than a sample:
// this is the property the deleted normalizeKVBackendTag/…FallbackTag pair was
// defending against, and it is cheaper to prove than to re-check per request.
func TestKVBackendTagsAreNeverEmpty(t *testing.T) {
	kinds := []string{"", production.KVBackendPaged, production.KVBackendContiguous, "paged_quantized", "  ", "a:b"}
	reasons := []string{
		"", "kill_switch", "crash_loop_guard", "kernel_preflight: boom",
		"physical_capacity: 1 > 0", "ineligible: vlm",
		"pool_construction_capacity: x", "invalid_dtype: fp32",
		"unheard-of", ":", "  :  ",
		strings.Repeat("x", maxKVFallbackReasonBytes*2),
	}
	for _, observed := range []bool{true, false} {
		for _, kind := range kinds {
			if got := production.KVBackendTag(kind, observed); got == "" {
				t.Errorf("KVBackendTag(%q, %v) = \"\"", kind, observed)
			}
		}
		for _, reason := range reasons {
			if got := production.KVBackendFallbackTag(reason, observed); got == "" {
				t.Errorf("KVBackendFallbackTag(%q, %v) = \"\"", reason, observed)
			}
		}
	}
	if backend, fallback := production.UnknownKVBackendTags(); backend != production.KVBackendUnknown ||
		fallback != production.KVFallbackUnknown {
		t.Errorf("UnknownKVBackendTags() = (%q, %q)", backend, fallback)
	}
}

// The ticket in one test: two slots serving `contiguous`, one by choice and one
// because it was configured paged and paged did not happen. Before the fallback
// reason they were the same observation. BOTH halves are asserted — a field
// that is always present is not a signal, so the clean slot reporting `none`
// matters exactly as much as the degraded one reporting its class.
func TestSlotKVBackendFallbackSeparatesChoiceFromDegrade(t *testing.T) {
	r, histories := newKVBackendRegistry()
	const model = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	chose := registerKVProvider(t, r, "box-chose-contiguous", model)
	fell := registerKVProvider(t, r, "box-degraded-to-contiguous", model)
	legacy := registerKVProvider(t, r, "box-pre-080", model)

	r.Heartbeat(chose, kvHeartbeat(kvSlot(model, kvStr(production.KVBackendContiguous))))
	r.Heartbeat(fell, kvHeartbeat(kvSlotDegraded(
		model, production.KVBackendContiguous, "kernel_preflight: paged kernels unavailable")))
	r.Heartbeat(legacy, kvHeartbeat(kvSlot(model, nil)))

	// The resolved kind CANNOT tell the first two apart. That is the defect.
	if slotKVBackendTag(r, chose, model) != slotKVBackendTag(r, fell, model) {
		t.Fatalf("premise broken: the two slots should agree on the resolved kind")
	}

	// The fallback dimension can.
	choose, chooseObserved := observeKVBackend(r, histories, chose, model)
	chooseReason := choose.FallbackReason
	if !chooseObserved {
		t.Fatal("a slot that named a backend must count as observed")
	}
	if chooseReason != "" {
		t.Errorf("deliberate contiguous reported reason %q, want none", chooseReason)
	}
	fellObs, fellObserved := observeKVBackend(r, histories, fell, model)
	fellReason := fellObs.FallbackReason
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
		{chose, production.KVBackendContiguous, production.KVFallbackNone},
		{fell, production.KVBackendContiguous, production.KVFallbackKernelPreflight},
		{legacy, production.KVBackendUnknown, production.KVFallbackUnknown},
	} {
		backend, fallback := r.SlotKVBackendTags(tc.id, model)
		if backend != tc.wantBackend || fallback != tc.wantFallback {
			t.Errorf("%s = (%q, %q), want (%q, %q)",
				tc.id, backend, fallback, tc.wantBackend, tc.wantFallback)
		}
	}
}

// A hostile or future provider must not park an unbounded string in coordinator
// state for the life of the session, but the class must still survive.
func TestSlotKVBackendFallbackReasonIsClamped(t *testing.T) {
	r, histories := newKVBackendRegistry()
	const model = "gemma"
	id := registerKVProvider(t, r, "box-verbose", model)

	long := "ineligible: " + strings.Repeat("x", maxKVFallbackReasonBytes*4)
	r.Heartbeat(id, kvHeartbeat(kvSlotDegraded(model, production.KVBackendContiguous, long)))

	obs, observed := observeKVBackend(r, histories, id, model)
	stored := obs.FallbackReason
	if !observed {
		t.Fatal("slot not observed")
	}
	if len(stored) != maxKVFallbackReasonBytes {
		t.Errorf("stored %d bytes, want the clamp %d", len(stored), maxKVFallbackReasonBytes)
	}
	// Truncation is from the tail: the leading class the metric groups on is
	// exactly what must survive.
	if _, fallback := r.SlotKVBackendTags(id, model); fallback != production.KVFallbackIneligible {
		t.Errorf("clamped reason tagged %q, want %q", fallback, production.KVFallbackIneligible)
	}
}
