package registry_test

import (
	"math"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func rowsFor(rows []store.FleetSnapshotRow, providerID string) []store.FleetSnapshotRow {
	var out []store.FleetSnapshotRow
	for _, r := range rows {
		if r.ProviderID == providerID {
			out = append(out, r)
		}
	}
	return out
}

func TestFleetSampleShape(t *testing.T) {
	production.ResetTTFTCalibration()
	reg := production.New(testLogger())
	reg.SetModelCatalog([]production.CatalogEntry{{ID: ctxModel}, {ID: ctxOtherModel}})
	now := time.Now()

	// A: two resident slots, one with an unrecognised (provider-invented) state.
	a := makeSchedulerProvider(t, reg, "prov-a", ctxModel, 40)
	reg.MergeProviderModels(a.ID, []protocol.ModelInfo{{ID: ctxOtherModel, ModelType: "chat", Quantization: "4bit"}})
	a.Mu().Lock()
	a.BackendCapacity.Slots[0].NumRunning = 2
	a.BackendCapacity.Slots[0].ObservedDecodeTPS = 33
	a.BackendCapacity.Slots[0].StepsExecuted = 99
	a.BackendCapacity.Slots[0].MaxConcurrency = 6
	a.BackendCapacity.Slots = append(a.BackendCapacity.Slots, a.BackendCapacity.Slots[0])
	a.BackendCapacity.Slots[1].Model = ctxOtherModel
	a.BackendCapacity.Slots[1].State = "weird-new-state"
	a.BackendCapacity.Slots[1].NumRunning = 0
	a.BackendCapacity.GPUMemoryPeakGB = 41.5
	a.Stats.RequestsServed = 7
	a.Stats.TokensGenerated = 7000
	a.LastHeartbeat = now.Add(-3 * time.Second)
	a.SystemMetrics.ThermalState = "fair"
	a.Mu().Unlock()
	a.AddPending(&production.PendingRequest{RequestID: "inflight-a", Model: ctxModel, RequestedMaxTokens: 64})

	// B: crashed slot.
	b := makeSchedulerProvider(t, reg, "prov-b", ctxModel, 40)
	b.Mu().Lock()
	b.BackendCapacity.Slots[0].State = "crashed"
	b.SystemMetrics.ThermalState = "bizarre"
	b.Mu().Unlock()

	// C: no capacity report at all: one provider-level row.
	c := makeSchedulerProvider(t, reg, "prov-c", ctxModel, 40)
	c.Mu().Lock()
	c.BackendCapacity = nil
	c.Mu().Unlock()

	// D: warm slot but breaker open.
	d := makeSchedulerProvider(t, reg, "prov-d", ctxModel, 40)
	for i := 0; i < identitygate.ProviderBreakerConsecTrip; i++ {
		reg.RecordProviderOutcome(d.ID, false, 500, "internal fault")
	}

	// E: offline, no capacity: provider-level row naming the liveness gate.
	e := makeSchedulerProvider(t, reg, "prov-e", ctxModel, 40)
	e.Mu().Lock()
	e.BackendCapacity = nil
	e.Status = production.StatusOffline
	e.Mu().Unlock()

	rows := reg.FleetSample(now)
	if len(rows) != 6 {
		t.Fatalf("rows = %d, want 6 (2+1+1+1+1)", len(rows))
	}
	for _, r := range rows {
		if !r.SampledAt.Equal(now) {
			t.Fatalf("row %s/%s SampledAt = %v", r.ProviderID, r.Model, r.SampledAt)
		}
		if r.HeartbeatAgeMs < 0 {
			t.Fatalf("row %s/%s negative heartbeat age", r.ProviderID, r.Model)
		}
		switch production.SlotState(r.SlotState) {
		case production.SlotStateRunning, production.SlotStateIdle, production.SlotStateIdleShutdown, production.SlotStateCrashed, production.SlotStateReloading, production.SlotStateOther:
		default:
			t.Fatalf("row %s/%s SlotState %q outside the closed vocabulary", r.ProviderID, r.Model, r.SlotState)
		}
	}

	aa := rowFor(t, rows, "prov-a", ctxModel)
	if aa.SlotState != string(production.SlotStateRunning) || aa.NumRunning != 2 || aa.ObservedDecodeTPS != 33 || aa.StepsExecuted != 99 {
		t.Fatalf("prov-a/%s row = %+v", ctxModel, aa)
	}
	if aa.EligibilityReason != production.EligibilityReasonEligible {
		t.Fatalf("prov-a eligibility = %q, want eligible", aa.EligibilityReason)
	}
	if aa.MaxConcurrency != 6 || aa.EffectiveCap <= 0 || aa.PendingCount != 1 {
		t.Fatalf("prov-a caps/pending = %d/%d/%d", aa.MaxConcurrency, aa.EffectiveCap, aa.PendingCount)
	}
	if aa.RequestsServed != 7 || aa.TokensGenerated != 7000 || aa.GPUMemoryPeakGB != 41.5 || aa.ThermalState != "fair" {
		t.Fatalf("prov-a provider-level fields = %+v", aa)
	}
	if aa.HeartbeatAgeMs < 2900 || aa.HeartbeatAgeMs > 5000 {
		t.Fatalf("prov-a HeartbeatAgeMs = %d, want ≈ 3000", aa.HeartbeatAgeMs)
	}
	if aa.CooldownActive || aa.BreakerOpen || aa.ClampActive || aa.Ejected {
		t.Fatalf("prov-a flags = %+v", aa)
	}
	ab := rowFor(t, rows, "prov-a", ctxOtherModel)
	if ab.SlotState != string(production.SlotStateOther) {
		t.Fatalf("prov-a/%s SlotState = %q, want other (folded)", ctxOtherModel, ab.SlotState)
	}
	if ab.PendingCount != 0 {
		t.Fatalf("prov-a/%s PendingCount = %d, want 0 (per-slot)", ctxOtherModel, ab.PendingCount)
	}

	bb := rowFor(t, rows, "prov-b", ctxModel)
	if bb.SlotState != string(production.SlotStateCrashed) || bb.EligibilityReason != production.GateSlotCrashed.String() {
		t.Fatalf("prov-b row = state %q reason %q", bb.SlotState, bb.EligibilityReason)
	}
	if bb.ThermalState != "other" {
		t.Fatalf("prov-b ThermalState = %q, want other (folded)", bb.ThermalState)
	}

	cc := rowsFor(rows, "prov-c")
	if len(cc) != 1 || cc[0].Model != "" || cc[0].SlotState != string(production.SlotStateOther) || cc[0].EligibilityReason != production.EligibilityReasonEligible {
		t.Fatalf("prov-c rows = %+v", cc)
	}

	dd := rowFor(t, rows, "prov-d", ctxModel)
	if !dd.BreakerOpen || dd.EligibilityReason != production.GateBreaker.String() {
		t.Fatalf("prov-d row = breaker %v reason %q", dd.BreakerOpen, dd.EligibilityReason)
	}

	ee := rowsFor(rows, "prov-e")
	if len(ee) != 1 || ee[0].EligibilityReason != production.GateOffline.String() {
		t.Fatalf("prov-e rows = %+v", ee)
	}
}

func TestFleetSampleCooldownAndClampFlags(t *testing.T) {
	reg := production.New(testLogger())
	reg.SetModelCatalog([]production.CatalogEntry{{ID: ctxModel}})
	p := makeSchedulerProvider(t, reg, "cool", ctxModel, 40)
	for i := 0; i < identitygate.DefaultCapacityCooldownThreshold; i++ {
		reg.RecordCapacityReject(p.ID, ctxModel)
	}
	rows := reg.FleetSample(time.Now())
	row := rowFor(t, rows, "cool", ctxModel)
	if !row.CooldownActive || row.EligibilityReason != production.GateCapacityCooldown.String() {
		t.Fatalf("row = cooldown %v reason %q", row.CooldownActive, row.EligibilityReason)
	}
}

func TestCoordinatorSample(t *testing.T) {
	reg := production.New(testLogger())
	q := production.NewRequestQueue(8, time.Minute)
	reg.SetQueue(q)
	p := makeSchedulerProvider(t, reg, "p1", ctxModel, 40)
	p.AddPending(&production.PendingRequest{RequestID: "inflight-1", Model: ctxModel, RequestedMaxTokens: 64})
	p.AddPending(&production.PendingRequest{RequestID: "inflight-2", Model: ctxModel, RequestedMaxTokens: 64})
	for _, id := range []string{"a1", "a2"} {
		if err := q.Enqueue(&production.QueuedRequest{RequestID: id, Model: ctxModel}); err != nil {
			t.Fatalf("enqueue: %v", err)
		}
	}
	if err := q.Enqueue(&production.QueuedRequest{RequestID: "b1", Model: ctxOtherModel}); err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	now := time.Now()
	row := reg.CoordinatorSample(now)
	if row.ProviderID != "coordinator" || !row.SampledAt.Equal(now) {
		t.Fatalf("row = %+v", row)
	}
	if row.InflightRequests != 2 {
		t.Fatalf("InflightRequests = %d, want 2", row.InflightRequests)
	}
	if row.QueueDepthTotal != 3 {
		t.Fatalf("QueueDepthTotal = %d, want 3", row.QueueDepthTotal)
	}
	want := `{"` + ctxModel + `":2,"` + ctxOtherModel + `":1}`
	if string(row.QueueDepthByModel) != want {
		t.Fatalf("QueueDepthByModel = %s, want %s", row.QueueDepthByModel, want)
	}
	if row.SlotState != string(production.SlotStateOther) {
		t.Fatalf("coordinator SlotState = %q, want other", row.SlotState)
	}

	// Empty queue: no by-model object at all (omission = nothing queued).
	empty := production.New(testLogger()).CoordinatorSample(now)
	if empty.QueueDepthTotal != 0 || empty.QueueDepthByModel != nil || empty.InflightRequests != 0 {
		t.Fatalf("empty coordinator row = %+v", empty)
	}
}

// The sampler must release its registry lease before waiting on a provider.
// SetQueue performs a real write transaction without touching either provider.
func TestFleetSampleNotSerializedBehindProviderLock(t *testing.T) {
	reg := production.New(testLogger())
	a := makeSchedulerProvider(t, reg, "lock-a", ctxModel, 40)
	b := makeSchedulerProvider(t, reg, "lock-b", ctxModel, 40)
	a.Mu().Lock()
	b.Mu().Lock()

	done := make(chan []store.FleetSnapshotRow, 1)
	go func() { done <- reg.FleetSample(time.Now()) }()
	time.Sleep(50 * time.Millisecond)
	runtime.Gosched()

	written := make(chan struct{})
	go func() {
		reg.SetQueue(production.NewRequestQueue(8, time.Minute))
		close(written)
	}()
	select {
	case <-written:
	case <-time.After(time.Second):
		a.Mu().Unlock()
		b.Mu().Unlock()
		t.Fatal("FleetSample holds r.mu while waiting for a provider lock (whole-walk RLock)")
	}

	a.Mu().Unlock()
	b.Mu().Unlock()
	select {
	case rows := <-done:
		if len(rows) != 2 {
			t.Fatalf("rows = %d, want 2", len(rows))
		}
	case <-time.After(5 * time.Second):
		t.Fatal("FleetSample did not complete after the provider locks were released")
	}
}

func TestFleetSampleCopiesModelCapabilities(t *testing.T) {
	reg := production.New(testLogger())
	reg.SetModelCatalog([]production.CatalogEntry{{ID: ctxModel}, {ID: ctxOtherModel}})
	now := time.Now()

	a := makeSchedulerProvider(t, reg, "prov-a", ctxModel, 40)
	reg.MergeProviderModels(a.ID, []protocol.ModelInfo{{ID: ctxOtherModel, ModelType: "chat", Quantization: "4bit"}})
	a.Mu().Lock()
	a.Version = " 0.8.13 "
	a.Models[0].IsVision = true
	a.Models[1].TemplateRenderOK = telBool(false)
	a.BackendCapacity.Slots = append(a.BackendCapacity.Slots, a.BackendCapacity.Slots[0])
	a.BackendCapacity.Slots[1].Model = ctxOtherModel
	a.Mu().Unlock()

	b := makeSchedulerProvider(t, reg, "prov-b", ctxModel, 40)
	b.Mu().Lock()
	b.Version = "v0.8; drop table"
	b.BackendCapacity.Slots[0].Model = ctxOtherModel // advertised: ctxModel only
	b.Mu().Unlock()

	c := makeSchedulerProvider(t, reg, "prov-c", ctxModel, 40)
	c.Mu().Lock()
	c.Version = ""
	c.BackendCapacity = nil
	c.Mu().Unlock()

	rows := reg.FleetSample(now)
	aa := rowFor(t, rows, "prov-a", ctxModel)
	if aa.ProviderVersion != "0.8.13" || !aa.ModelVision || aa.TemplateRenderOK != nil {
		t.Fatalf("prov-a/%s = version %q vision %v render_ok %v, want 0.8.13/true/nil", ctxModel, aa.ProviderVersion, aa.ModelVision, aa.TemplateRenderOK)
	}
	ab := rowFor(t, rows, "prov-a", ctxOtherModel)
	if ab.ProviderVersion != "0.8.13" || ab.ModelVision || ab.TemplateRenderOK == nil || *ab.TemplateRenderOK {
		t.Fatalf("prov-a/%s = version %q vision %v render_ok %v, want 0.8.13/false/false", ctxOtherModel, ab.ProviderVersion, ab.ModelVision, ab.TemplateRenderOK)
	}
	bb := rowFor(t, rows, "prov-b", ctxOtherModel)
	if bb.ProviderVersion != production.ProviderVersionUnparseable || bb.ModelVision || bb.TemplateRenderOK != nil {
		t.Fatalf("prov-b row = version %q vision %v render_ok %v, want the sentinel and no flags for an unadvertised slot model", bb.ProviderVersion, bb.ModelVision, bb.TemplateRenderOK)
	}
	cc := rowsFor(rows, "prov-c")
	if len(cc) != 1 || cc[0].ProviderVersion != "" || cc[0].ModelVision || cc[0].TemplateRenderOK != nil {
		t.Fatalf("prov-c provider-level row = %+v, want no version and no flags", cc)
	}
	coord := reg.CoordinatorSample(now)
	if coord.ProviderVersion != "" || coord.ModelVision || coord.TemplateRenderOK != nil {
		t.Fatalf("coordinator row carries capability columns: %+v", coord)
	}
	a.Mu().Lock()
	*a.Models[1].TemplateRenderOK = true
	a.Mu().Unlock()
	if *ab.TemplateRenderOK {
		t.Fatal("row aliases ModelInfo.TemplateRenderOK")
	}
}

func TestProviderVersionFold(t *testing.T) {
	cases := map[string]string{
		"": "", "  ": "", "0.8.13": "0.8.13", " 0.8.13\n": "0.8.13",
		"0.8.13-rc.1": "0.8.13-rc.1", "999.999.9999": "999.999.9999",
		"v0.8.13":                           production.ProviderVersionUnparseable,
		"0.8":                               production.ProviderVersionUnparseable,
		"0.8.13.1":                          production.ProviderVersionUnparseable,
		"1000.0.0":                          production.ProviderVersionUnparseable,
		"0.8.13-RC.1":                       production.ProviderVersionUnparseable,
		"0.8.13-" + strings.Repeat("a", 17): production.ProviderVersionUnparseable,
		"v0.8; drop":                        production.ProviderVersionUnparseable,
		"0.8.13; drop":                      production.ProviderVersionUnparseable,
		"=HYPERLINK(1)":                     production.ProviderVersionUnparseable,
	}
	for in, want := range cases {
		got := production.ProviderVersionFold(in)
		if got != want {
			t.Errorf("ProviderVersionFold(%q) = %q, want %q", in, got, want)
		}
		if len(got) > 32 {
			t.Errorf("ProviderVersionFold(%q) = %q exceeds 32 bytes", in, got)
		}
	}
	if production.CompareVersions(production.ProviderVersionFold("0.9.9"), "0.9.6") < 0 {
		t.Fatal("folded version must compare above the qwen4 catalog-policy floor")
	}
	if production.CompareVersions(production.ProviderVersionFold("junk"), "0.9.6") >= 0 {
		t.Fatal("the sentinel must compare below the qwen4 catalog-policy floor")
	}
}

func rowFor(t *testing.T, rows []store.FleetSnapshotRow, providerID, model string) store.FleetSnapshotRow {
	t.Helper()
	for _, r := range rows {
		if r.ProviderID == providerID && r.Model == model {
			return r
		}
	}
	t.Fatalf("no row for %s/%s", providerID, model)
	return store.FleetSnapshotRow{}
}

// TestCoordinatorSampleDoesNotExpireStaleWaiters: enabling the profiler must
// never change a client outcome. A stale waiter must survive a sample untouched
// (no Done close, no nil ResponseCh send, still counted), whereas the mutating
// QueuedModels sweep — which the sampler must not use — would expire it.
func TestCoordinatorSampleDoesNotExpireStaleWaiters(t *testing.T) {
	reg := production.New(testLogger())
	q := production.NewRequestQueue(8, 50*time.Millisecond)
	reg.SetQueue(q)
	req := &production.QueuedRequest{RequestID: "stale", Model: ctxModel}
	if err := q.Enqueue(req); err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	req.EnqueuedAt = time.Now().Add(-time.Second) // well past maxWait

	row := reg.CoordinatorSample(time.Now())
	select {
	case <-req.Done():
		t.Fatal("CoordinatorSample expired a stale waiter (Done closed)")
	default:
	}
	if len(req.ResponseCh) != 0 {
		t.Fatal("CoordinatorSample signalled a stale waiter on ResponseCh")
	}
	if q.QueueSize(ctxModel) != 1 || row.QueueDepthTotal != 1 {
		t.Fatalf("stale waiter dropped from the queue: size=%d depth=%d", q.QueueSize(ctxModel), row.QueueDepthTotal)
	}
	if string(row.QueueDepthByModel) != `{"`+ctxModel+`":1}` {
		t.Fatalf("QueueDepthByModel = %s", row.QueueDepthByModel)
	}

	// Contrast: the mutating accessor DOES expire it — which is exactly why the
	// sampler must not call it.
	q.QueuedModels()
	select {
	case <-req.Done():
	default:
		t.Fatal("QueuedModels no longer sweeps stale waiters; revisit this test's premise")
	}
}

// TestFleetSampleFoldsUncataloguedSlotModel: fleet_snapshots.model must only
// ever be a coordinator-catalog id. A provider-authored slot model the catalog
// does not know is folded to the sentinel, the row is still emitted (capacity
// stays visible), and the raw string never reaches a row.
func TestFleetSampleFoldsUncataloguedSlotModel(t *testing.T) {
	reg := production.New(testLogger())
	reg.SetModelCatalog([]production.CatalogEntry{{ID: ctxModel}})
	const rogue = "vendor/private-build-that-is-not-in-the-catalog"
	p := makeSchedulerProvider(t, reg, "folded", ctxModel, 40)
	p.Mu().Lock()
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, p.BackendCapacity.Slots[0])
	p.BackendCapacity.Slots[1].Model = rogue
	p.BackendCapacity.Slots[1].NumRunning = 3
	p.Mu().Unlock()

	rows := reg.FleetSample(time.Now())
	if len(rows) != 2 {
		t.Fatalf("rows = %d, want 2", len(rows))
	}
	for _, r := range rows {
		if r.Model == rogue {
			t.Fatalf("raw provider slot model reached a row: %+v", r)
		}
	}
	good := rowFor(t, rows, "folded", ctxModel)
	if good.EligibilityReason != production.EligibilityReasonEligible {
		t.Fatalf("catalog slot eligibility = %q, want eligible", good.EligibilityReason)
	}
	folded := rowFor(t, rows, "folded", production.FleetSnapshotModelUncatalogued)
	if folded.NumRunning != 3 || folded.SlotState != string(production.SlotStateRunning) {
		t.Fatalf("folded row lost its capacity fields: %+v", folded)
	}
	if folded.EligibilityReason != production.GateNotServingModel.String() {
		t.Fatalf("folded row eligibility = %q, want not_serving_model", folded.EligibilityReason)
	}

	// Nil catalog (never synced / sync failed): there is no id to vouch for
	// any provider string, so every slot model folds to the sentinel.
	dev := production.New(testLogger())
	makeSchedulerProvider(t, dev, "dev", ctxModel, 40)
	devRows := dev.FleetSample(time.Now())
	if len(devRows) != 1 || devRows[0].Model != production.FleetSnapshotModelUncatalogued {
		t.Fatalf("nil-catalog rows = %+v, want one row with Model %q", devRows, production.FleetSnapshotModelUncatalogued)
	}
}

func i64(v int64) *int64 { return &v }

func f64(v float64) *float64 { return &v }

func telBool(v bool) *bool { return &v }

// TestFleetSampleCopiesHeartbeatTelemetry: the slice-2 slot + capacity
// telemetry sub-objects and the HeartbeatStats cancel counters land on the
// row; a provider without them leaves the fields zero/nil; the row never
// aliases the heartbeat's pointers.
func TestFleetSampleCopiesHeartbeatTelemetry(t *testing.T) {
	reg := production.New(testLogger())
	reg.SetModelCatalog([]production.CatalogEntry{{ID: ctxModel}})
	p := makeSchedulerProvider(t, reg, "telemetry", ctxModel, 40)
	p.Mu().Lock()
	p.BackendCapacity.Telemetry = &protocol.CapacityTelemetry{
		LowPowerMode:        telBool(true),
		MemoryPressureLevel: protocol.MemoryPressureWarning,
		MLXNumResources:     i64(5),
	}
	p.BackendCapacity.Slots[0].EvalInFlightMs = 1 // legacy field, superseded below
	p.BackendCapacity.Slots[0].Telemetry = &protocol.SlotTelemetry{
		QueuedPrefillTokens: i64(1200),
		PartialPrefillRows:  i64(2),
		PrefillTokensTotal:  i64(99000),
		IsolatedPrefillTPS:  f64(850.5),
		EWMAInitialized:     telBool(true),
		PumpTasks:           i64(3),
		MTPRoundsTotal:      i64(10),
		MTPProposedTotal:    i64(30),
		MTPAcceptedTotal:    i64(21),
		KVBytesInUse:        i64(1 << 30),
		KVBytesCapacity:     i64(4 << 30),
		EvalInFlightMS:      i64(77),
		StepWallNSTotal:     i64(123456789),
		DecodeRowsTotal:     i64(4321),
	}
	p.Stats.CancelStagePreAcceptTotal = 1
	p.Stats.CancelStagePreEngineTotal = 2
	p.Stats.CancelStagePrefillTotal = 3
	p.Stats.CancelStageDecodeTotal = 4
	p.Stats.CancelStagePostTerminalTotal = 5
	p.Stats.TokensAfterCancelTotal = 60
	p.Stats.CancelAbortNSSum = 7000
	p.Mu().Unlock()

	row := rowFor(t, reg.FleetSample(time.Now()), "telemetry", ctxModel)
	if row.QueuedPrefillTokens != 1200 || row.PartialPrefillRows != 2 || row.PrefillTokensTotal != 99000 ||
		row.IsolatedPrefillTPS != 850.5 || row.EWMAInitialized == nil || !*row.EWMAInitialized ||
		row.MTPRoundsTotal != 10 || row.MTPProposedTotal != 30 || row.MTPAcceptedTotal != 21 ||
		row.KVBytesInUse != 1<<30 || row.KVBytesCapacity != 4<<30 || row.EvalInFlightMs != 77 ||
		row.StepWallNSTotal != 123456789 || row.DecodeRowsTotal != 4321 {
		t.Fatalf("slot telemetry not copied: %+v", row)
	}
	if row.LowPowerMode == nil || !*row.LowPowerMode || row.MemoryPressureLevel != string(protocol.MemoryPressureWarning) {
		t.Fatalf("capacity telemetry not copied: low_power=%v level=%q", row.LowPowerMode, row.MemoryPressureLevel)
	}
	if row.CancelStagePreAcceptTotal != 1 || row.CancelStagePreEngineTotal != 2 || row.CancelStagePrefillTotal != 3 ||
		row.CancelStageDecodeTotal != 4 || row.CancelStagePostTerminalTotal != 5 || row.TokensAfterCancelTotal != 60 ||
		row.CancelAbortNSSum != 7000 {
		t.Fatalf("cancel counters not copied: %+v", row)
	}
	// No aliasing: flipping the heartbeat's pointer must not change the row.
	p.Mu().Lock()
	*p.BackendCapacity.Telemetry.LowPowerMode = false
	*p.BackendCapacity.Slots[0].Telemetry.EWMAInitialized = false
	p.Mu().Unlock()
	if !*row.LowPowerMode || !*row.EWMAInitialized {
		t.Fatal("row aliases the heartbeat telemetry pointers")
	}

	// Unknown level folds; absent sub-objects leave nil/zero.
	p.Mu().Lock()
	p.BackendCapacity.Telemetry.MemoryPressureLevel = protocol.MemoryPressureLevel("melting")
	p.Mu().Unlock()
	if got := rowFor(t, reg.FleetSample(time.Now()), "telemetry", ctxModel).MemoryPressureLevel; got != string(protocol.MemoryPressureOther) {
		t.Fatalf("MemoryPressureLevel = %q, want other", got)
	}
	legacy := makeSchedulerProvider(t, reg, "legacy", ctxModel, 40)
	legacy.Mu().Lock()
	legacy.BackendCapacity.Slots[0].EvalInFlightMs = 9
	legacy.Mu().Unlock()
	lrow := rowFor(t, reg.FleetSample(time.Now()), "legacy", ctxModel)
	if lrow.LowPowerMode != nil || lrow.EWMAInitialized != nil || lrow.MemoryPressureLevel != "" ||
		lrow.QueuedPrefillTokens != 0 || lrow.KVBytesCapacity != 0 || lrow.EvalInFlightMs != 9 {
		t.Fatalf("legacy provider row should be zero/nil for telemetry fields (legacy eval_in_flight kept): %+v", lrow)
	}
}

func TestClampFleetRowIntsBoundsEveryIntColumn(t *testing.T) {
	huge := int(math.MaxInt32) + 12345
	row := store.FleetSnapshotRow{
		NumRunning: huge, NumWaiting: huge, QueuedPrefillTokens: huge, PartialPrefillRows: huge,
		MaxConcurrency: huge, PendingCount: huge, EffectiveCap: huge, HeartbeatAgeMs: -huge,
		QueueDepthTotal: huge, InflightRequests: huge, ProfileSinkDepth: huge, Goroutines: huge,
	}
	production.ClampFleetRowInts(&row)
	for name, v := range map[string]int{
		"num_running": row.NumRunning, "num_waiting": row.NumWaiting, "queued_prefill_tokens": row.QueuedPrefillTokens,
		"partial_prefill_rows": row.PartialPrefillRows, "max_concurrency": row.MaxConcurrency, "pending_count": row.PendingCount,
		"effective_cap": row.EffectiveCap, "queue_depth_total": row.QueueDepthTotal, "inflight_requests": row.InflightRequests,
		"profile_sink_depth": row.ProfileSinkDepth, "goroutines": row.Goroutines,
	} {
		if v != math.MaxInt32 {
			t.Fatalf("%s = %d, want MaxInt32", name, v)
		}
	}
	if row.HeartbeatAgeMs != math.MinInt32 {
		t.Fatalf("heartbeat_age_ms = %d, want MinInt32", row.HeartbeatAgeMs)
	}
	small := store.FleetSnapshotRow{NumRunning: 3, HeartbeatAgeMs: 250}
	production.ClampFleetRowInts(&small)
	if small.NumRunning != 3 || small.HeartbeatAgeMs != 250 {
		t.Fatalf("in-range values must be untouched: %+v", small)
	}
}
