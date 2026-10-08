package registry

import (
	"context"
	"slices"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Desired mode is durable. Sessions describe only this coordinator's current
// verified bindings and effective control, never historical inventory aliases.
type MachineAutopilotStatus struct {
	store.MachineAutopilotSetting
	Sessions []MachineAutopilotSession `json:"sessions"`
}

type MachineAutopilotSession struct {
	ProviderID            string     `json:"provider_id"`
	MachineModel          string     `json:"machine_model"`
	ChipName              string     `json:"chip_name"`
	MemoryGB              int        `json:"memory_gb"`
	EffectiveMode         string     `json:"effective_mode"`
	ControlActive         bool       `json:"control_active"`
	Consented             bool       `json:"consented"`
	Paused                bool       `json:"paused"`
	PrivateOnly           bool       `json:"private_only"`
	CapacityFresh         bool       `json:"capacity_fresh"`
	LastHeartbeat         *time.Time `json:"last_heartbeat"`
	CapacityAcceptedAt    *time.Time `json:"capacity_accepted_at"`
	IdleUnloadMins        *int       `json:"idle_unload_mins"`
	AlwaysReadyConfigured *bool      `json:"always_ready_configured"`
	// Null lists mean no usable report; [] means a report with no entries.
	PinnedModels   []string `json:"pinned_models"`
	ResidentModels []string `json:"resident_models"`
}

func (r *Registry) ListMachineAutopilot(ctx context.Context, after string, limit int) ([]MachineAutopilotStatus, error) {
	settings, ok := store.As[store.MachineAutopilotStore](r.store)
	if !ok {
		return nil, ErrMachineAutopilotUnavailable
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	rows, err := settings.ListMachineAutopilotSettings(ctx, after, limit)
	if err != nil {
		return nil, err
	}
	return r.machineAutopilotStatuses(rows), nil
}

func (r *Registry) machineAutopilotStatuses(settings []store.MachineAutopilotSetting) []MachineAutopilotStatus {
	result := make([]MachineAutopilotStatus, len(settings))
	indices := make(map[string]int, len(settings))
	for i, setting := range settings {
		result[i] = MachineAutopilotStatus{MachineAutopilotSetting: setting, Sessions: []MachineAutopilotSession{}}
		indices[setting.MachineID] = i
	}
	r.mu.RLock()
	now := time.Now()
	c := r.autopilot
	for _, p := range r.providers {
		p.mu.Lock()
		account, machine := p.VerifiedMachineIdentityLocked()
		if i, found := indices[machine]; found && account != "" && account == p.AccountID && p.Status != StatusOffline {
			result[i].Sessions = append(result[i].Sessions, machineAutopilotSessionLocked(c, p, now))
		}
		p.mu.Unlock()
	}
	r.mu.RUnlock()
	for i := range result {
		slices.SortFunc(result[i].Sessions, func(a, b MachineAutopilotSession) int { return strings.Compare(a.ProviderID, b.ProviderID) })
	}
	return result
}

func machineAutopilotSessionLocked(c *modelAutopilotController, p *Provider, now time.Time) MachineAutopilotSession {
	s := MachineAutopilotSession{
		ProviderID: p.ID, MachineModel: p.Hardware.MachineModel, ChipName: p.Hardware.ChipName, MemoryGB: p.Hardware.MemoryGB,
		EffectiveMode: "disabled", Consented: providerAutopilotConsentedLocked(p), PrivateOnly: p.PrivateOnly,
	}
	if !p.LastHeartbeat.IsZero() {
		at := p.LastHeartbeat
		s.LastHeartbeat = &at
	}
	if !p.CapacityAcceptedAt.IsZero() {
		at := p.CapacityAcceptedAt
		s.CapacityAcceptedAt = &at
	}
	if p.IdleUnloadMins != nil {
		minutes := *p.IdleUnloadMins
		alwaysReady := minutes == 0
		s.IdleUnloadMins, s.AlwaysReadyConfigured = &minutes, &alwaysReady
	}
	// Report policy independently of consent/control. Sanitized malformed states
	// have no cached-only contract and must not look like a known empty pin set.
	if state := p.ModelAutopilot; state != nil && state.Protocol == protocol.ModelAutopilotProtocol && state.CachedOnly {
		s.PinnedModels = append([]string{}, state.PinnedModels...)
		slices.Sort(s.PinnedModels)
		s.ResidentModels = autopilot.ResidentIDs(state)
	}
	s.Paused = p.ModelAutopilot != nil && p.ModelAutopilot.Paused
	maxAge := DefaultProviderHeartbeatTimeout
	if c != nil {
		s.Paused = s.Paused || c.paused.Load()
		switch {
		case !c.config.Enabled:
		case s.Paused:
			s.EffectiveMode = "paused"
		case s.PrivateOnly:
			s.EffectiveMode = "private"
		case !s.Consented:
			s.EffectiveMode = "unconsented"
		case !c.liveMachineLocked(p):
			s.EffectiveMode = "shadow"
		case !p.autopilotState.ControlActive(p.ModelAutopilot, p.ID, now):
			s.EffectiveMode = "awaiting_ack"
		default:
			s.EffectiveMode, s.ControlActive = "live", true
		}
		if s.ControlActive {
			maxAge = c.config.ControlSnapshotMaxAge()
		} else {
			maxAge = max(maxAge, c.config.ControlSnapshotMaxAge())
		}
	}
	s.CapacityFresh = p.BackendCapacity != nil && p.capacitySamples.Fresh(now, maxAge)
	return s
}
