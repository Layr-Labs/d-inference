package routingsim

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// coordinatorSnapshotProviderID is the provider_id of the per-tick coordinator
// row in fleet_snapshots (registry.CoordinatorSample); it is not a provider.
const coordinatorSnapshotProviderID = "coordinator"

// ProviderSpec is one provider reconstructed from the fleet_snapshots rows of
// a single sampler tick: its hardware (from the override map or the default),
// the models it advertises, the per-slot capacity the router scores, and the
// provider-level capacity/system metrics carried by every row.
type ProviderSpec struct {
	ID       string
	Hardware HardwareSpec
	// Models is the advertised model set: every non-empty model named by the
	// provider's rows plus Hardware.Models, sorted and deduplicated.
	Models []string
	// Slots is one BackendSlotCapacity per (provider, model) row, in Models
	// order. The provider-level row (model "") contributes no slot.
	Slots []protocol.BackendSlotCapacity
	// System is the folded system metrics the row carried. ThermalState is
	// "" when the snapshot folded it to "other".
	System protocol.SystemMetrics
	// GPUMemoryActiveGB / GPUMemoryPeakGB / FreeForLoadGB are the
	// BackendCapacity-level fields; FreeForLoadGB is nil when the snapshot
	// carried 0 (legacy provider or unreported), mirroring the wire pointer.
	GPUMemoryActiveGB float64
	GPUMemoryPeakGB   float64
	FreeForLoadGB     *float64
	// Version is the provider binary version the snapshot recorded
	// (fleet_snapshots.provider_version, already folded by
	// registry.ProviderVersionFold). Build applies it to Provider.Version, the
	// field the capability version floors (tools) compare against. "" when
	// the export predates the column: tool-bearing arrivals are then rejected,
	// which is honest — the snapshot does not know the floor was met.
	Version string
	// ModelFlags carries, per advertised model id, the capability flags the
	// slot row recorded for it. A model with no entry (a hardware-override
	// model, or an export that predates the columns) advertises neither
	// vision nor a template-render opinion.
	ModelFlags map[string]ModelFlags
}

// ModelFlags is the per-model capability advertisement a fleet_snapshots slot
// row carries: the provider's ModelInfo.IsVision (vision gate) and
// ModelInfo.TemplateRenderOK (template-render gate; nil = no opinion).
type ModelFlags struct {
	Vision           bool
	TemplateRenderOK *bool
}

// FleetSpec is a fleet reconstructed from one fleet_snapshots tick. Build
// registers it into a real registry.Registry.
//
// What a snapshot cannot rebuild (documented, not silently defaulted): the
// coordinator-side pending count per provider, open breakers, cooldowns,
// budget clamps and health ejections. Those columns are recorded on the row
// for the reader's benefit, but the loader only reconstructs the provider and
// slot state the preflight classifier consumes; a replay that needs fault
// state must apply it itself. Capability gating IS rebuilt: the provider
// version (tools floor) and the per-model vision / template-render flags come
// from the row when the export carries them.
type FleetSpec struct {
	// SampledAt is the tick the fleet was reconstructed from.
	SampledAt time.Time
	// Providers is sorted by ID.
	Providers []ProviderSpec
}

// LoadFleetNDJSON reads a fleet_snapshots export — the admin
// GET /v1/admin/snapshots/export format: one store.FleetSnapshotRow JSON
// object per line — and reconstructs the fleet as of the sampler tick nearest
// to at. A zero at selects the latest tick; a tie between two equidistant
// ticks selects the earlier one. Rows from other ticks are ignored, as is the
// coordinator row.
//
// hardware supplies the chip identity, memory, bandwidth and static decode TPS
// the snapshot does not carry, keyed by provider_id; nil or a missing key
// falls back to DefaultHardwareSpec (the BuildFleet hardware). Slot state is
// the snapshot's folded vocabulary passed straight through, except "other",
// which becomes the coordinator's "unknown" (model advertised, not resident,
// cold-load penalty).
//
// Blank lines are ignored. A malformed line fails the whole load with an error
// naming the 1-based line number.
func LoadFleetNDJSON(r io.Reader, at time.Time, hardware map[string]HardwareSpec) (FleetSpec, error) {
	if r == nil {
		return FleetSpec{}, errors.New("routingsim: nil snapshots reader")
	}
	var rows []store.FleetSnapshotRow
	err := forEachNDJSONLine(r, func(lineNo int, line []byte) error {
		var row store.FleetSnapshotRow
		if err := json.Unmarshal(line, &row); err != nil {
			return fmt.Errorf("routingsim: snapshots ndjson line %d: %w", lineNo, err)
		}
		if row.SampledAt.IsZero() {
			return fmt.Errorf("routingsim: snapshots ndjson line %d: missing sampled_at", lineNo)
		}
		rows = append(rows, row)
		return nil
	})
	if err != nil {
		return FleetSpec{}, err
	}
	if len(rows) == 0 {
		return FleetSpec{}, errors.New("routingsim: snapshots ndjson has no rows")
	}
	tick := nearestTick(rows, at)
	return fleetSpecFromRows(rows, tick, hardware), nil
}

// nearestTick returns the sampled_at nearest to at among rows (earlier wins a
// tie); the latest tick when at is zero.
func nearestTick(rows []store.FleetSnapshotRow, at time.Time) time.Time {
	var best time.Time
	var bestDist time.Duration
	for _, row := range rows {
		t := row.SampledAt
		if best.IsZero() {
			best, bestDist = t, absDuration(t.Sub(at))
			continue
		}
		if at.IsZero() {
			if t.After(best) {
				best = t
			}
			continue
		}
		d := absDuration(t.Sub(at))
		if d < bestDist || (d == bestDist && t.Before(best)) {
			best, bestDist = t, d
		}
	}
	return best
}

func absDuration(d time.Duration) time.Duration {
	if d < 0 {
		return -d
	}
	return d
}

// fleetSpecFromRows groups the rows of tick by provider and reconstructs each
// provider's spec.
func fleetSpecFromRows(rows []store.FleetSnapshotRow, tick time.Time, hardware map[string]HardwareSpec) FleetSpec {
	byProvider := map[string][]store.FleetSnapshotRow{}
	var order []string
	for _, row := range rows {
		if !row.SampledAt.Equal(tick) || row.ProviderID == coordinatorSnapshotProviderID || row.ProviderID == "" {
			continue
		}
		if _, seen := byProvider[row.ProviderID]; !seen {
			order = append(order, row.ProviderID)
		}
		byProvider[row.ProviderID] = append(byProvider[row.ProviderID], row)
	}
	sort.Strings(order)

	spec := FleetSpec{SampledAt: tick, Providers: make([]ProviderSpec, 0, len(order))}
	for _, id := range order {
		hw := DefaultHardwareSpec()
		if hardware != nil {
			if override, ok := hardware[id]; ok {
				hw = override
			}
		}
		spec.Providers = append(spec.Providers, providerSpecFromRows(id, hw, byProvider[id]))
	}
	return spec
}

// providerSpecFromRows builds one ProviderSpec from a provider's rows at a
// tick. Provider-level fields are taken from the first row (the sampler
// stamps the same values on every row of a provider).
func providerSpecFromRows(id string, hw HardwareSpec, rows []store.FleetSnapshotRow) ProviderSpec {
	first := rows[0]
	ps := ProviderSpec{
		ID:                id,
		Hardware:          hw,
		System:            protocol.SystemMetrics{MemoryPressure: first.MemoryPressure, CPUUsage: first.CPUUsage, ThermalState: thermalStateUnfold(first.ThermalState)},
		GPUMemoryActiveGB: first.GPUMemoryActiveGB,
		GPUMemoryPeakGB:   first.GPUMemoryPeakGB,
		Version:           first.ProviderVersion,
		ModelFlags:        map[string]ModelFlags{},
	}
	// Presence is the signal: nil means the provider never reported
	// free-for-load (legacy → heuristic), while an explicit 0 is a saturated
	// provider that the live scheduler refuses cold loads on — keep it 0.
	if first.FreeForLoadGB != nil {
		v := *first.FreeForLoadGB
		ps.FreeForLoadGB = &v
	}

	// Slots: one per model row, deduplicated on model (first row wins). The
	// same first row supplies the model's capability flags.
	slotByModel := map[string]protocol.BackendSlotCapacity{}
	modelSet := map[string]struct{}{}
	for _, row := range rows {
		if row.Model == "" {
			continue // provider-level row: no resident slot
		}
		modelSet[row.Model] = struct{}{}
		if _, dup := slotByModel[row.Model]; dup {
			continue
		}
		flags := ModelFlags{Vision: row.ModelVision}
		if row.TemplateRenderOK != nil {
			ok := *row.TemplateRenderOK
			flags.TemplateRenderOK = &ok
		}
		ps.ModelFlags[row.Model] = flags
		slotByModel[row.Model] = protocol.BackendSlotCapacity{
			Model:                 row.Model,
			State:                 slotStateUnfold(row.SlotState),
			NumRunning:            row.NumRunning,
			NumWaiting:            row.NumWaiting,
			MaxConcurrency:        row.MaxConcurrency,
			ActiveTokenBudgetUsed: row.ActiveTokenBudgetUsed,
			ActiveTokenBudgetMax:  row.ActiveTokenBudgetMax,
			ObservedDecodeTPS:     row.ObservedDecodeTPS,
			ObservedPrefillTPS:    row.ObservedPrefillTPS,
		}
	}
	for _, m := range hw.Models {
		if m != "" {
			modelSet[m] = struct{}{}
		}
	}
	ps.Models = make([]string, 0, len(modelSet))
	for m := range modelSet {
		ps.Models = append(ps.Models, m)
	}
	sort.Strings(ps.Models)
	ps.Slots = make([]protocol.BackendSlotCapacity, 0, len(slotByModel))
	for _, m := range ps.Models {
		if slot, ok := slotByModel[m]; ok {
			ps.Slots = append(ps.Slots, slot)
		}
	}
	return ps
}

// slotStateUnfold maps the snapshot's folded slot state (registry.SlotState)
// back onto the wire value the scheduler scores. The five named states are
// their own wire value; "other" (and anything unexpected) is the
// coordinator's "unknown": advertised, not resident, cold-load penalty.
func slotStateUnfold(folded string) string {
	switch registry.SlotState(folded) {
	case registry.SlotStateRunning, registry.SlotStateIdle, registry.SlotStateIdleShutdown,
		registry.SlotStateCrashed, registry.SlotStateReloading:
		return folded
	default:
		return "unknown"
	}
}

// thermalStateUnfold passes the four named thermal states through and turns
// the fold's "other" into an empty (unreported) state.
func thermalStateUnfold(folded string) string {
	switch folded {
	case "nominal", "fair", "serious", "critical":
		return folded
	default:
		return ""
	}
}

// modelInfos is the advertised model list p registers with: every Models id
// as a chat/4-bit ModelInfo (the routingsim default) carrying the capability
// flags the snapshot recorded for it, so the reconstructed Provider.Models
// answers the vision and template-render gates exactly as the live one did.
func (p ProviderSpec) modelInfos() []protocol.ModelInfo {
	infos := simModelInfos(p.Models)
	for i := range infos {
		flags, ok := p.ModelFlags[infos[i].ID]
		if !ok {
			continue
		}
		infos[i].IsVision = flags.Vision
		if flags.TemplateRenderOK != nil {
			v := *flags.TemplateRenderOK
			infos[i].TemplateRenderOK = &v
		}
	}
	return infos
}

// staticDecodeTPS resolves the registration-time decode TPS for p: the
// hardware override when set, else the fastest observed slot EWMA at the
// tick, else 0 (the registry then derives a rate from memory bandwidth).
func (p ProviderSpec) staticDecodeTPS() float64 {
	if p.Hardware.DecodeTPS > 0 {
		return p.Hardware.DecodeTPS
	}
	best := 0.0
	for _, slot := range p.Slots {
		if slot.ObservedDecodeTPS > best {
			best = slot.ObservedDecodeTPS
		}
	}
	return best
}

// Build registers every provider of the spec into a fresh registry through
// the same public path a live provider takes — registry.Register with the
// spec's hardware and models, one registry.Heartbeat carrying the
// reconstructed BackendCapacity and system metrics (so the registry's own
// canonicalisation and clamps apply), then the attestation arming BuildFleet
// uses (armSimProvider + RecordChallengeSuccess) so every provider is
// routable. The registry uses the default in-memory store (nil) and the
// default MinTrustLevel.
func (f FleetSpec) Build(logger *slog.Logger) (*registry.Registry, error) {
	if len(f.Providers) == 0 {
		return nil, errors.New("routingsim: FleetSpec has no providers")
	}
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	}
	reg := registry.New(logger)
	for _, ps := range f.Providers {
		if ps.ID == "" {
			return nil, errors.New("routingsim: FleetSpec provider with empty ID")
		}
		hw := ps.Hardware
		if hw.MemoryGB <= 0 {
			hw.MemoryGB = DefaultHardwareSpec().MemoryGB
		}
		if hw.MemoryBandwidthGBs <= 0 {
			hw.MemoryBandwidthGBs = DefaultHardwareSpec().MemoryBandwidthGBs
		}
		p := reg.Register(ps.ID, nil, simRegisterMessage(hw, ps.modelInfos(), ps.staticDecodeTPS()))
		armSimProvider(p)
		// Register does not read the register message's version; the api layer
		// stores it on the provider under its lock (api/provider.go, "Store
		// provider version"). Same path here so the tools version floor
		// (registry.providerMeetsTraitFloorsLocked) sees what the snapshot saw.
		if ps.Version != "" {
			p.Mu().Lock()
			p.Version = ps.Version
			p.Mu().Unlock()
		}

		slots := append([]protocol.BackendSlotCapacity(nil), ps.Slots...)
		var warm []string
		for _, slot := range slots {
			if slot.State == string(registry.SlotStateRunning) || slot.State == string(registry.SlotStateIdle) {
				warm = append(warm, slot.Model)
			}
		}
		var freeForLoad *float64
		if ps.FreeForLoadGB != nil {
			v := *ps.FreeForLoadGB
			freeForLoad = &v
		}
		reg.Heartbeat(ps.ID, &protocol.HeartbeatMessage{
			Type:          protocol.TypeHeartbeat,
			WarmModels:    warm,
			SystemMetrics: ps.System,
			BackendCapacity: &protocol.BackendCapacity{
				Slots:             slots,
				GPUMemoryActiveGB: ps.GPUMemoryActiveGB,
				GPUMemoryPeakGB:   ps.GPUMemoryPeakGB,
				TotalMemoryGB:     float64(hw.MemoryGB),
				FreeForLoadGB:     freeForLoad,
			},
		})
		reg.RecordChallengeSuccess(ps.ID)
	}
	return reg, nil
}
