package store

import (
	"context"
	"errors"
)

type MachineAutopilotMode string

const (
	MachineAutopilotShadow MachineAutopilotMode = "shadow"
	MachineAutopilotLive   MachineAutopilotMode = "live"
)

var ErrInvalidMachineAutopilotMode = errors.New("invalid_machine_autopilot_mode")

type MachineAutopilotSetting struct {
	MachineID   string               `json:"machine_id"`
	DesiredMode MachineAutopilotMode `json:"desired_mode"`
	Revision    int64                `json:"revision"`
}

// MachineAutopilotStore persists operator intent, not runtime authority. Only
// existing, unmerged machine IDs are eligible; setters never follow aliases.
type MachineAutopilotStore interface {
	// List uses an exclusive machine ID cursor, default limit 100, maximum 200.
	// Unconfigured machines are included as shadow at revision zero.
	ListMachineAutopilotSettings(ctx context.Context, after string, limit int) ([]MachineAutopilotSetting, error)
	// Live returns every unmerged live setting, ordered by machine ID.
	LiveMachineAutopilotSettings(ctx context.Context) ([]MachineAutopilotSetting, error)
	// Set increments the revision only when the desired mode changes.
	// Unknown or merged-away IDs return ErrNotFound.
	SetMachineAutopilotDesiredMode(ctx context.Context, machineID string, mode MachineAutopilotMode) (MachineAutopilotSetting, error)
}
