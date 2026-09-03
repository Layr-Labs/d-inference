package routingsim_test

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/routingsim"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const simModel2 = "mlx-community/gemma-4-26b-it-4bit"

func snapshotsNDJSON(t *testing.T, rows ...store.FleetSnapshotRow) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	for i, row := range rows {
		b, err := json.Marshal(row)
		if err != nil {
			t.Fatalf("marshal row %d: %v", i, err)
		}
		buf.Write(b)
		buf.WriteByte('\n')
	}
	return &buf
}

func slotRow(at time.Time, provider, model, state string, running int, tps float64) store.FleetSnapshotRow {
	return store.FleetSnapshotRow{
		SampledAt: at, ProviderID: provider, Model: model, EligibilityReason: "eligible", SlotState: state,
		NumRunning: running, NumWaiting: 1, ActiveTokenBudgetUsed: 1000, ActiveTokenBudgetMax: 65536,
		ObservedDecodeTPS: tps, ObservedPrefillTPS: 900, MaxConcurrency: 4,
		MemoryPressure: 0.2, CPUUsage: 0.3, ThermalState: "nominal",
		GPUMemoryActiveGB: 30, GPUMemoryPeakGB: 33, FreeForLoadGB: ptrF64(12),
	}
}

// snapshotFixtures returns two ticks 60 s apart. Tick 1: prov-a with two
// resident slots, prov-b with a slot in a folded-away state, prov-c with only
// a provider-level row, plus the coordinator row. Tick 2: prov-a busier and a
// new prov-d, plus the coordinator row.
func snapshotFixtures(tick1 time.Time) []store.FleetSnapshotRow {
	tick2 := tick1.Add(time.Minute)
	coord := func(at time.Time) store.FleetSnapshotRow {
		return store.FleetSnapshotRow{SampledAt: at, ProviderID: "coordinator", SlotState: "other", QueueDepthTotal: 3, Goroutines: 100}
	}
	provC := store.FleetSnapshotRow{SampledAt: tick1, ProviderID: "prov-c", SlotState: "other", ThermalState: "other", MemoryPressure: 0.9}
	return []store.FleetSnapshotRow{
		coord(tick1),
		slotRow(tick1, "prov-a", simModel, "running", 1, 25),
		slotRow(tick1, "prov-a", simModel2, "idle", 0, 20),
		slotRow(tick1, "prov-b", simModel, "other", 0, 0),
		provC,
		// tick 2, written out of order to prove grouping is by sampled_at.
		slotRow(tick2, "prov-d", simModel, "running", 0, 27),
		coord(tick2),
		slotRow(tick2, "prov-a", simModel, "running", 3, 24),
	}
}

func providerIDs(f routingsim.FleetSpec) []string {
	ids := make([]string, 0, len(f.Providers))
	for _, p := range f.Providers {
		ids = append(ids, p.ID)
	}
	return ids
}

func TestLoadFleetNDJSONPicksNearestTick(t *testing.T) {
	tick1 := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	tick2 := tick1.Add(time.Minute)
	rows := snapshotFixtures(tick1)

	// Nearest to tick 2.
	f, err := routingsim.LoadFleetNDJSON(snapshotsNDJSON(t, rows...), tick2.Add(-10*time.Second), nil)
	if err != nil {
		t.Fatalf("LoadFleetNDJSON: %v", err)
	}
	if !f.SampledAt.Equal(tick2) {
		t.Fatalf("SampledAt = %s, want tick2 %s", f.SampledAt, tick2)
	}
	if got := providerIDs(f); strings.Join(got, ",") != "prov-a,prov-d" {
		t.Fatalf("tick2 providers = %v, want [prov-a prov-d] (coordinator row skipped)", got)
	}
	a := f.Providers[0]
	if len(a.Slots) != 1 || a.Slots[0].Model != simModel || a.Slots[0].State != "running" || a.Slots[0].NumRunning != 3 {
		t.Fatalf("tick2 prov-a slots = %+v, want one running slot with 3 running", a.Slots)
	}
	if a.Slots[0].ObservedDecodeTPS != 24 || a.Slots[0].ObservedPrefillTPS != 900 || a.Slots[0].MaxConcurrency != 4 ||
		a.Slots[0].ActiveTokenBudgetUsed != 1000 || a.Slots[0].ActiveTokenBudgetMax != 65536 || a.Slots[0].NumWaiting != 1 {
		t.Fatalf("tick2 prov-a slot fields not carried: %+v", a.Slots[0])
	}
	if a.System.MemoryPressure != 0.2 || a.System.ThermalState != "nominal" || a.GPUMemoryActiveGB != 30 || a.FreeForLoadGB == nil || *a.FreeForLoadGB != 12 {
		t.Fatalf("tick2 prov-a provider-level fields not carried: %+v", a)
	}
	if def := routingsim.DefaultHardwareSpec(); a.Hardware.ChipFamily != def.ChipFamily || a.Hardware.MemoryGB != def.MemoryGB || a.Hardware.DecodeTPS != 0 {
		t.Fatalf("prov-a hardware = %+v, want the default", a.Hardware)
	}

	// Nearest to tick 1, with a hardware override for prov-c that also names
	// the model it advertises.
	hw := map[string]routingsim.HardwareSpec{
		"prov-c": {ChipName: "Apple M4 Pro", ChipFamily: "M4", ChipTier: "Pro", MemoryGB: 48, MemoryBandwidthGBs: 273, GPUCores: 20, Models: []string{simModel}},
	}
	f, err = routingsim.LoadFleetNDJSON(snapshotsNDJSON(t, rows...), tick1.Add(20*time.Second), hw)
	if err != nil {
		t.Fatalf("LoadFleetNDJSON(tick1): %v", err)
	}
	if !f.SampledAt.Equal(tick1) {
		t.Fatalf("SampledAt = %s, want tick1", f.SampledAt)
	}
	if got := providerIDs(f); strings.Join(got, ",") != "prov-a,prov-b,prov-c" {
		t.Fatalf("tick1 providers = %v", got)
	}
	a, b, c := f.Providers[0], f.Providers[1], f.Providers[2]
	// Models/Slots are sorted by model id (byte order: "Qwen" < "gemma").
	if strings.Join(a.Models, ",") != simModel+","+simModel2 || len(a.Slots) != 2 || a.Slots[0].State != "running" || a.Slots[1].State != "idle" {
		t.Fatalf("tick1 prov-a = models %v slots %+v", a.Models, a.Slots)
	}
	if len(b.Slots) != 1 || b.Slots[0].State != "unknown" {
		t.Fatalf("folded 'other' slot state must unfold to \"unknown\", got %+v", b.Slots)
	}
	if len(c.Slots) != 0 || strings.Join(c.Models, ",") != simModel || c.Hardware.ChipFamily != "M4" || c.Hardware.MemoryGB != 48 {
		t.Fatalf("prov-c (provider-level row + override) = %+v", c)
	}
	if c.System.ThermalState != "" || c.System.MemoryPressure != 0.9 || c.FreeForLoadGB != nil {
		t.Fatalf("prov-c system metrics = %+v free=%v", c.System, c.FreeForLoadGB)
	}

	// Zero at → latest tick; an exact midpoint tie → the earlier tick.
	if f, err = routingsim.LoadFleetNDJSON(snapshotsNDJSON(t, rows...), time.Time{}, nil); err != nil || !f.SampledAt.Equal(tick2) {
		t.Fatalf("zero at → (%s, %v), want tick2", f.SampledAt, err)
	}
	if f, err = routingsim.LoadFleetNDJSON(snapshotsNDJSON(t, rows...), tick1.Add(30*time.Second), nil); err != nil || !f.SampledAt.Equal(tick1) {
		t.Fatalf("tie → (%s, %v), want tick1", f.SampledAt, err)
	}
}

func TestLoadFleetNDJSONErrors(t *testing.T) {
	tick1 := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	buf := snapshotsNDJSON(t, snapshotFixtures(tick1)[:2]...)
	buf.WriteString("{not json\n")
	if _, err := routingsim.LoadFleetNDJSON(buf, tick1, nil); err == nil || !strings.Contains(err.Error(), "line 3") {
		t.Fatalf("malformed line error = %v, want one naming line 3", err)
	}
	if _, err := routingsim.LoadFleetNDJSON(strings.NewReader(`{"provider_id":"p","model":"m"}`+"\n"), tick1, nil); err == nil || !strings.Contains(err.Error(), "sampled_at") {
		t.Fatalf("missing sampled_at error = %v", err)
	}
	if _, err := routingsim.LoadFleetNDJSON(strings.NewReader(""), tick1, nil); err == nil {
		t.Fatal("empty export must error")
	}
	if _, err := routingsim.LoadFleetNDJSON(nil, tick1, nil); err == nil {
		t.Fatal("nil reader must error")
	}
	// A tick with only the coordinator row reconstructs nothing to build.
	coordOnly := snapshotsNDJSON(t, store.FleetSnapshotRow{SampledAt: tick1, ProviderID: "coordinator"})
	f, err := routingsim.LoadFleetNDJSON(coordOnly, tick1, nil)
	if err != nil || len(f.Providers) != 0 {
		t.Fatalf("coordinator-only tick = (%+v, %v)", f, err)
	}
	if _, err := f.Build(nil); err == nil {
		t.Fatal("Build of an empty FleetSpec must error")
	}
}

func TestFleetSpecBuildRegistersRoutableProviders(t *testing.T) {
	tick1 := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	hw := map[string]routingsim.HardwareSpec{
		"prov-c": {ChipName: "Apple M4 Pro", ChipFamily: "M4", ChipTier: "Pro", MemoryGB: 48, MemoryBandwidthGBs: 273, GPUCores: 20, Models: []string{simModel}, DecodeTPS: 18},
	}
	f, err := routingsim.LoadFleetNDJSON(snapshotsNDJSON(t, snapshotFixtures(tick1)...), tick1, hw)
	if err != nil {
		t.Fatalf("LoadFleetNDJSON: %v", err)
	}
	reg, err := f.Build(nil)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if got := reg.ProviderCount(); got != 3 {
		t.Fatalf("ProviderCount = %d, want 3", got)
	}
	if reg.GetProvider("coordinator") != nil {
		t.Fatal("coordinator row was registered as a provider")
	}

	a := reg.GetProvider("prov-a")
	if a == nil {
		t.Fatal("prov-a not registered")
	}
	a.Mu().Lock()
	var slots []struct{ Model, State string }
	if a.BackendCapacity != nil {
		for _, s := range a.BackendCapacity.Slots {
			slots = append(slots, struct{ Model, State string }{s.Model, s.State})
		}
	}
	warm := append([]string(nil), a.WarmModels...)
	family, memGB, decode := a.Hardware.ChipFamily, a.Hardware.MemoryGB, a.DecodeTPS
	a.Mu().Unlock()
	if len(slots) != 2 || slots[0].Model != simModel || slots[0].State != "running" || slots[1].Model != simModel2 || slots[1].State != "idle" {
		t.Fatalf("prov-a registry slots = %+v", slots)
	}
	if strings.Join(warm, ",") != simModel+","+simModel2 {
		t.Fatalf("prov-a warm models = %v", warm)
	}
	if family != "M3" || memGB != 64 || decode != 25 { // static TPS derived from the fastest observed slot
		t.Fatalf("prov-a hardware/decode = %s %d %.0f, want M3 64 25", family, memGB, decode)
	}

	c := reg.GetProvider("prov-c")
	c.Mu().Lock()
	cFamily, cMem, cDecode, cSlots := c.Hardware.ChipFamily, c.Hardware.MemoryGB, c.DecodeTPS, 0
	if c.BackendCapacity != nil {
		cSlots = len(c.BackendCapacity.Slots)
	}
	c.Mu().Unlock()
	if cFamily != "M4" || cMem != 48 || cDecode != 18 || cSlots != 0 {
		t.Fatalf("prov-c = %s %d %.0f slots=%d, want M4 48 18 0", cFamily, cMem, cDecode, cSlots)
	}

	// The reconstructed fleet is routable through the real preflight: prov-a's
	// running slot (and cold prov-b/prov-c) are candidates for simModel.
	candidates, capacityRejections, tooLarge, _, hasTTFT :=
		reg.QuickCapacityCheckWithTTFTForRequest(simModel, 300, 128, registry.RequestTraits{}, false)
	if candidates == 0 || !hasTTFT {
		t.Fatalf("preflight: candidates=%d capacityRejections=%d tooLarge=%d hasTTFT=%v", candidates, capacityRejections, tooLarge, hasTTFT)
	}
}

// TestClassifyWithGateFromNDJSON is the end-to-end path: a request_profiles
// export and a fleet_snapshots export → trace + fleet → the existing
// ClassifyWithGate → Report. The arrivals carry the production traits
// (coord-a has tools, coord-c requires vision), so the replay only serves
// them when the snapshot lets the reconstructed fleet pass the tools version
// floor and the vision gate.
func TestClassifyWithGateFromNDJSON(t *testing.T) {
	defer routingsim_setRatio(t, 12.0)()
	t0 := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	tick := t0.Add(-15 * time.Second)

	// The profile export: three winning arrivals (+ a loser and a shapeless
	// row that must not count) spanning the small and large prompt buckets.
	trace, err := routingsim.LoadProfilesNDJSON(profilesNDJSON(t, profileFixtures(t0)...))
	if err != nil {
		t.Fatalf("LoadProfilesNDJSON: %v", err)
	}
	if len(trace) != 3 {
		t.Fatalf("trace has %d arrivals, want 3", len(trace))
	}
	if !trace[0].HasTools || !trace[2].RequiresVision {
		t.Fatalf("fixture traits drifted: %+v", trace)
	}

	// A warm, idle three-provider fleet for simModel at the sampler tick
	// preceding the first arrival. withCapabilities stamps what a current
	// sampler records: a provider version past the tools floor on every row
	// and the vision advertisement on prov-2's slot (the provider that served
	// coord-c in production).
	buildFleet := func(t *testing.T, withCapabilities bool) *registry.Registry {
		t.Helper()
		var rows []store.FleetSnapshotRow
		for _, id := range []string{"prov-1", "prov-2", "prov-3"} {
			row := slotRow(tick, id, simModel, "running", 0, 25)
			if withCapabilities {
				row.ProviderVersion = "0.8.13"
				row.ModelVision = id == "prov-2"
			}
			rows = append(rows, row)
		}
		rows = append(rows, store.FleetSnapshotRow{SampledAt: tick, ProviderID: "coordinator"})
		fleet, err := routingsim.LoadFleetNDJSON(snapshotsNDJSON(t, rows...), t0, nil)
		if err != nil {
			t.Fatalf("LoadFleetNDJSON: %v", err)
		}
		reg, err := fleet.Build(nil)
		if err != nil {
			t.Fatalf("Build: %v", err)
		}
		return reg
	}

	t.Run("capabilities recorded", func(t *testing.T) {
		reg := buildFleet(t, true)
		results := routingsim.RunWithGate(reg, trace, true) // soft gate
		report := routingsim.Summarize(results)
		t.Logf("ndjson replay:\n%s", report.String())
		if report.Total != 3 || report.MachineBusy != 0 || report.Served != 3 {
			t.Fatalf("soft-gate report = %+v, want 3 served on an idle warm fleet whose snapshot carries the capability gates", report)
		}
		for _, label := range []string{"0-500", "750-1000", "1000-2000"} {
			if b, ok := report.Bucket(label); !ok || b.Total != 1 || b.Served != 1 {
				t.Fatalf("bucket %s = %+v, want 1 served", label, b)
			}
		}
		for i, r := range results {
			if r.Outcome != routingsim.OutcomeServed {
				t.Fatalf("arrival %d (%s) outcome = %q, want served", i, r.Arrival.CoordRequestID, r.Outcome)
			}
		}
		// Per-arrival results keep the production context for scoring.
		if results[2].Arrival.ChosenProviderID != "prov-2" || results[2].Arrival.ActualTTFTMs != 400 {
			t.Fatalf("result 2 lost its production context: %+v", results[2].Arrival)
		}
		// The hard gate on the same replay classifies every arrival too (the
		// ×12 estimate keeps a 1200-token prompt under the deadline).
		if hard := routingsim.Summarize(routingsim.Run(reg, trace)); hard.Total != 3 || hard.MachineBusy != 0 || hard.Served != 3 {
			t.Fatalf("hard-gate report = %+v", hard)
		}
	})

	// An export from before the capability columns (provider_version "",
	// model_vision false): the reconstructed providers have no version, so
	// the tools floor rejects coord-a, and no slot advertises vision, so
	// coord-c finds no provider. The replay must say so (no_provider, never
	// served) rather than invent capabilities the snapshot did not record.
	t.Run("legacy export without capabilities", func(t *testing.T) {
		reg := buildFleet(t, false)
		results := routingsim.RunWithGate(reg, trace, true)
		report := routingsim.Summarize(results)
		t.Logf("legacy ndjson replay:\n%s", report.String())
		if report.Total != 3 || report.MachineBusy != 0 || report.Served != 1 {
			t.Fatalf("soft-gate report = %+v, want only the plain-text arrival served", report)
		}
		if b, ok := report.Bucket("750-1000"); !ok || b.Total != 1 || b.Served != 1 {
			t.Fatalf("bucket 750-1000 = %+v, want the plain-text arrival served", b)
		}
		for _, label := range []string{"0-500", "1000-2000"} {
			if b, ok := report.Bucket(label); !ok || b.Total != 1 || b.Served != 0 || b.NoProvider != 1 {
				t.Fatalf("bucket %s = %+v, want the gated arrival unserved", label, b)
			}
		}
		if results[0].Outcome != routingsim.OutcomeNoProvider {
			t.Fatalf("tools arrival outcome = %q, want no_provider (no provider version → below the tools floor)", results[0].Outcome)
		}
		if results[1].Outcome != routingsim.OutcomeServed {
			t.Fatalf("plain arrival outcome = %q, want served", results[1].Outcome)
		}
		if results[2].Outcome != routingsim.OutcomeNoProvider {
			t.Fatalf("vision arrival outcome = %q, want no_provider", results[2].Outcome)
		}
	})
}

// TestFleetSpecCarriesCapabilities: the version and per-model flags on the
// rows land on ProviderSpec and, through Build, on the live Provider the
// routing gates read; a row without them leaves the provider version empty
// and the model flags unset.
func TestFleetSpecCarriesCapabilities(t *testing.T) {
	tick := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	renderOK := false
	vision := slotRow(tick, "prov-v", simModel, "running", 0, 25)
	vision.ProviderVersion, vision.ModelVision = "0.8.13", true
	broken := slotRow(tick, "prov-v", simModel2, "idle", 0, 20)
	broken.ProviderVersion, broken.TemplateRenderOK = "0.8.13", &renderOK
	legacy := slotRow(tick, "prov-l", simModel, "running", 0, 25)
	rows := []store.FleetSnapshotRow{vision, broken, legacy, {SampledAt: tick, ProviderID: "coordinator"}}

	f, err := routingsim.LoadFleetNDJSON(snapshotsNDJSON(t, rows...), tick, nil)
	if err != nil {
		t.Fatalf("LoadFleetNDJSON: %v", err)
	}
	if got := providerIDs(f); strings.Join(got, ",") != "prov-l,prov-v" {
		t.Fatalf("providers = %v", got)
	}
	l, v := f.Providers[0], f.Providers[1]
	if v.Version != "0.8.13" || !v.ModelFlags[simModel].Vision || v.ModelFlags[simModel].TemplateRenderOK != nil ||
		v.ModelFlags[simModel2].Vision || v.ModelFlags[simModel2].TemplateRenderOK == nil || *v.ModelFlags[simModel2].TemplateRenderOK {
		t.Fatalf("prov-v spec = version %q flags %+v", v.Version, v.ModelFlags)
	}
	if l.Version != "" || l.ModelFlags[simModel].Vision || l.ModelFlags[simModel].TemplateRenderOK != nil {
		t.Fatalf("prov-l (legacy row) spec = version %q flags %+v, want nothing", l.Version, l.ModelFlags)
	}
	// The spec never aliases the row's pointer.
	renderOK = true
	if *v.ModelFlags[simModel2].TemplateRenderOK {
		t.Fatal("ModelFlags.TemplateRenderOK aliases the snapshot row")
	}

	reg, err := f.Build(nil)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	pv := reg.GetProvider("prov-v")
	pv.Mu().Lock()
	version := pv.Version
	byID := map[string]struct {
		vision   bool
		renderOK *bool
	}{}
	for _, m := range pv.Models {
		byID[m.ID] = struct {
			vision   bool
			renderOK *bool
		}{m.IsVision, m.TemplateRenderOK}
	}
	pv.Mu().Unlock()
	if version != "0.8.13" {
		t.Fatalf("prov-v Provider.Version = %q, want 0.8.13", version)
	}
	if !byID[simModel].vision || byID[simModel].renderOK != nil {
		t.Fatalf("prov-v %s ModelInfo = %+v, want vision without a render opinion", simModel, byID[simModel])
	}
	if byID[simModel2].vision || byID[simModel2].renderOK == nil || *byID[simModel2].renderOK {
		t.Fatalf("prov-v %s ModelInfo = %+v, want template_render_ok=false", simModel2, byID[simModel2])
	}
	pl := reg.GetProvider("prov-l")
	pl.Mu().Lock()
	lVersion, lModels := pl.Version, append([]protocol.ModelInfo(nil), pl.Models...)
	pl.Mu().Unlock()
	if lVersion != "" || len(lModels) != 1 || lModels[0].IsVision || lModels[0].TemplateRenderOK != nil {
		t.Fatalf("prov-l = version %q models %+v, want no version and no flags", lVersion, lModels)
	}

	// The gates read them: prov-v serves tools (version ≥ floor) and vision
	// (IsVision) for simModel but never simModel2 (render-broken); prov-l
	// serves neither trait.
	if !reg.HasToolCapableProviderForModel(simModel) || !reg.HasVisionProviderForModel(simModel) {
		t.Fatal("prov-v must pass the tools floor and the vision gate for simModel")
	}
	if reg.HasToolCapableProviderForModel(simModel2) {
		t.Fatal("a template_render_ok=false slot must not pass the tools gate")
	}
	if candidates, _, _, _, _ := reg.QuickCapacityCheckWithTTFTForRequest(simModel2, 300, 128, registry.RequestTraits{}, false); candidates != 0 {
		t.Fatalf("render-broken simModel2 preflight candidates = %d, want 0", candidates)
	}
}

func ptrF64(v float64) *float64 { return &v }

// TestLoadFleetNDJSONPreservesReportedZeroFreeCapacity pins the presence
// semantics of free_for_load_gb: an explicit 0 from a current provider is a
// saturated box (kept as 0 so cold loads are refused exactly as live), while
// a nil (legacy, unreported) value falls back to the total-memory heuristic.
func TestLoadFleetNDJSONPreservesReportedZeroFreeCapacity(t *testing.T) {
	t0 := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	tick := t0.Add(-15 * time.Second)
	zero := slotRow(tick, "prov-zero", simModel, "running", 0, 25)
	zero.FreeForLoadGB = ptrF64(0)
	legacy := slotRow(tick, "prov-legacy", simModel, "running", 0, 25)
	legacy.FreeForLoadGB = nil
	fleet, err := routingsim.LoadFleetNDJSON(snapshotsNDJSON(t, zero, legacy, store.FleetSnapshotRow{SampledAt: tick, ProviderID: "coordinator"}), t0, nil)
	if err != nil {
		t.Fatalf("LoadFleetNDJSON: %v", err)
	}
	var sawZero, sawLegacy bool
	for _, ps := range fleet.Providers {
		switch ps.ID {
		case "prov-zero":
			sawZero = true
			if ps.FreeForLoadGB == nil || *ps.FreeForLoadGB != 0 {
				t.Fatalf("prov-zero FreeForLoadGB = %v, want an explicit 0", ps.FreeForLoadGB)
			}
		case "prov-legacy":
			sawLegacy = true
			if ps.FreeForLoadGB != nil {
				t.Fatalf("prov-legacy FreeForLoadGB = %v, want nil (heuristic)", *ps.FreeForLoadGB)
			}
		}
	}
	if !sawZero || !sawLegacy {
		t.Fatalf("providers missing from the reconstructed fleet: zero=%v legacy=%v", sawZero, sawLegacy)
	}
}
