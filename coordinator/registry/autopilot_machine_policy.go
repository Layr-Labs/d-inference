package registry

import (
	"context"
	"errors"
	"maps"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

var ErrMachineAutopilotUnavailable = errors.New("machine Autopilot settings unavailable")

type machineAutopilotPolicy struct {
	// Serializes persistence through publication, so an older periodic read
	// cannot overwrite an admin edit. Never acquire while holding registry.mu.
	updateMu sync.Mutex
	live     map[string]int64 // canonical machine -> revision; guarded by registry.mu
}

func (r *Registry) SetMachineAutopilotDesiredMode(ctx context.Context, machineID string, mode store.MachineAutopilotMode) (MachineAutopilotStatus, error) {
	if mode != store.MachineAutopilotShadow && mode != store.MachineAutopilotLive {
		return MachineAutopilotStatus{}, store.ErrInvalidMachineAutopilotMode
	}
	r.autopilotMachines.updateMu.Lock()
	defer r.autopilotMachines.updateMu.Unlock()
	settings, ok := store.As[store.MachineAutopilotStore](r.store)
	if !ok {
		r.publishMachineAutopilotPolicy(nil)
		r.refreshCurrentAutopilotLeases()
		return MachineAutopilotStatus{}, ErrMachineAutopilotUnavailable
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	setting, err := settings.SetMachineAutopilotDesiredMode(ctx, machineID, mode)
	if err != nil {
		// An interrupted write may have committed. Do not retain live authority
		// from an uncertain store result; a successful refresh can restore it.
		if !errors.Is(err, store.ErrNotFound) && !errors.Is(err, store.ErrInvalidMachineAutopilotMode) {
			r.publishMachineAutopilotPolicy(nil)
			r.refreshCurrentAutopilotLeases()
		}
		return MachineAutopilotStatus{}, err
	}
	r.mu.RLock()
	live := maps.Clone(r.autopilotMachines.live)
	r.mu.RUnlock()
	if mode == store.MachineAutopilotLive {
		if live == nil {
			live = make(map[string]int64)
		}
		live[machineID] = setting.Revision
	} else {
		delete(live, machineID)
	}
	r.publishMachineAutopilotPolicy(live)
	r.refreshCurrentAutopilotLeases()
	return r.machineAutopilotStatuses([]store.MachineAutopilotSetting{setting})[0], nil
}

func (r *Registry) refreshMachineAutopilotPolicy() {
	r.autopilotMachines.updateMu.Lock()
	defer r.autopilotMachines.updateMu.Unlock()
	settings, ok := store.As[store.MachineAutopilotStore](r.store)
	if !ok {
		r.publishMachineAutopilotPolicy(nil)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	rows, err := settings.LiveMachineAutopilotSettings(ctx)
	if err != nil {
		r.publishMachineAutopilotPolicy(nil)
		r.logger.Warn("Autopilot machine settings unavailable; withholding live control")
		return
	}
	live := make(map[string]int64, len(rows))
	for _, row := range rows {
		if row.DesiredMode == store.MachineAutopilotLive {
			live[row.MachineID] = row.Revision
		}
	}
	r.publishMachineAutopilotPolicy(live)
}

// Caller holds updateMu. Revocation and final reservation share registry.mu;
// accepted operations keep their owners, retries and terminal reconciliation.
func (r *Registry) publishMachineAutopilotPolicy(live map[string]int64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	previous := r.autopilotMachines.live
	r.autopilotMachines.live = live
	for _, p := range r.providers {
		p.mu.Lock()
		_, machineID := p.VerifiedMachineIdentityLocked()
		before, wasLive := previous[machineID]
		after, isLive := live[machineID]
		if wasLive != isLive || before != after {
			p.autopilotState.RevokeControl()
		}
		p.mu.Unlock()
	}
}

func (r *Registry) refreshCurrentAutopilotLeases() {
	r.mu.RLock()
	c := r.autopilot
	r.mu.RUnlock()
	if c != nil {
		c.refreshControlLeases(time.Now())
	}
}
