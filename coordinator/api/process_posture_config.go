package api

import "fmt"

// ProcessPostureMode controls the independent process posture policy.
// The zero value enforces; shadow must be selected explicitly.
type ProcessPostureMode string

const (
	ProcessPostureEnforce ProcessPostureMode = "enforce"
	ProcessPostureShadow  ProcessPostureMode = "shadow"
	ProcessPostureModeEnv                    = "EIGENINFERENCE_PROCESS_POSTURE_MODE"
)

func (m ProcessPostureMode) normalized() ProcessPostureMode {
	if m == "" {
		return ProcessPostureEnforce
	}
	return m
}

func (m ProcessPostureMode) Check() error {
	switch m.normalized() {
	case ProcessPostureEnforce, ProcessPostureShadow:
		return nil
	default:
		return fmt.Errorf("%s must be enforce or shadow, got %q", ProcessPostureModeEnv, m)
	}
}

func (s *Server) processPostureEnforced() bool {
	return s.processPostureMode.normalized() != ProcessPostureShadow
}
