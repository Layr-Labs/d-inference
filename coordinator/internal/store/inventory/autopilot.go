package inventory

import (
	"context"
	"sort"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *State) ListMachineAutopilotSettings(ctx context.Context, after string, limit int) ([]store.MachineAutopilotSetting, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if limit <= 0 {
		limit = 100
	} else if limit > 200 {
		limit = 200
	}
	settings := make([]store.MachineAutopilotSetting, 0)
	if s == nil {
		return settings, nil
	}
	for id := range s.Machines {
		if id > after {
			settings = append(settings, s.machineAutopilotSetting(id))
		}
	}
	sort.Slice(settings, func(i, j int) bool { return settings[i].MachineID < settings[j].MachineID })
	if len(settings) > limit {
		settings = settings[:limit]
	}
	return settings, nil
}

func (s *State) LiveMachineAutopilotSettings(ctx context.Context) ([]store.MachineAutopilotSetting, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	settings := make([]store.MachineAutopilotSetting, 0)
	if s == nil {
		return settings, nil
	}
	for _, setting := range s.autopilotSettings {
		if setting.DesiredMode == store.MachineAutopilotLive {
			settings = append(settings, setting)
		}
	}
	sort.Slice(settings, func(i, j int) bool { return settings[i].MachineID < settings[j].MachineID })
	return settings, nil
}

func (s *State) SetMachineAutopilotDesiredMode(ctx context.Context, machineID string, mode store.MachineAutopilotMode) (store.MachineAutopilotSetting, error) {
	if err := ctx.Err(); err != nil {
		return store.MachineAutopilotSetting{}, err
	}
	if mode != store.MachineAutopilotShadow && mode != store.MachineAutopilotLive {
		return store.MachineAutopilotSetting{}, store.ErrInvalidMachineAutopilotMode
	}
	if s == nil {
		return store.MachineAutopilotSetting{}, store.ErrNotFound
	}
	if _, exists := s.Machines[machineID]; !exists {
		return store.MachineAutopilotSetting{}, store.ErrNotFound
	}
	setting := s.machineAutopilotSetting(machineID)
	if setting.DesiredMode != mode {
		setting.DesiredMode = mode
		setting.Revision++
		if s.autopilotSettings == nil {
			s.autopilotSettings = make(map[string]store.MachineAutopilotSetting)
		}
		s.autopilotSettings[machineID] = setting
	}
	return setting, nil
}

func (s *State) machineAutopilotSetting(machineID string) store.MachineAutopilotSetting {
	if setting, exists := s.autopilotSettings[machineID]; exists {
		return setting
	}
	return store.MachineAutopilotSetting{MachineID: machineID, DesiredMode: store.MachineAutopilotShadow}
}
