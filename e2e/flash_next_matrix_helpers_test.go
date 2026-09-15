package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/eigeninference/d-inference/e2e/testbed"
)

const flashNextMatrixModel = "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp"

type flashNextMatrixSlot struct {
	Model             string  `json:"model"`
	KVBackend         *string `json:"kv_backend"`
	MTPEnabled        bool    `json:"mtp_enabled"`
	MTPActive         bool    `json:"mtp_active"`
	MTPInactiveReason *string `json:"mtp_inactive_reason"`
	LoadError         *string `json:"load_error"`
}

type flashNextMatrixState struct {
	PID             int                   `json:"pid"`
	WrittenAt       float64               `json:"written_at"`
	InferenceActive bool                  `json:"inference_active"`
	Slots           []flashNextMatrixSlot `json:"slots"`
}

func flashNextMatrixSnapshot(s *testbed.Suite, providerID, mode string) (flashNextMatrixState, bool) {
	var state flashNextMatrixState
	if len(s.Providers) != 1 || !s.Providers[0].Running() {
		return state, false
	}
	raw, err := os.ReadFile(s.Providers[0].DaemonStatePath())
	if err != nil || len(raw) > 1<<20 || json.Unmarshal(raw, &state) != nil || state.PID <= 1 || state.WrittenAt <= 0 || len(state.Slots) != 1 ||
		time.Since(time.UnixMilli(int64(state.WrittenAt*1000))) > 45*time.Second || state.InferenceActive {
		return state, false
	}
	p := s.Coordinator.Registry.GetProvider(providerID)
	if p == nil || p.PendingCount() != 0 || s.Coordinator.Registry.Queue().TotalSize() != 0 {
		return state, false
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.BackendCapacity == nil {
		return state, false
	}
	ready := false
	for _, slot := range p.BackendCapacity.Slots {
		if slot.Model == flashNextMatrixModel && slot.State == "idle" && slot.NumRunning == 0 && slot.NumWaiting == 0 {
			ready = true
		}
	}
	for _, slot := range state.Slots {
		if slot.Model == flashNextMatrixModel && slot.KVBackend != nil && *slot.KVBackend == "paged" && slot.LoadError == nil {
			if mode == "off" {
				return state, ready && !slot.MTPActive
			}
			return state, ready && slot.MTPEnabled && slot.MTPActive && slot.MTPInactiveReason == nil
		}
	}
	return state, false
}

func flashNextMatrixIdle(s *testbed.Suite, providerID, mode string) (flashNextMatrixState, error) {
	deadline := time.Now().Add(45 * time.Second)
	var last flashNextMatrixState
	for time.Now().Before(deadline) {
		state, ready := flashNextMatrixSnapshot(s, providerID, mode)
		last = state
		if ready {
			return state, nil
		}
		time.Sleep(250 * time.Millisecond)
	}
	return last, fmt.Errorf("real provider/coordinator did not report a fresh idle paged %s slot", mode)
}

func flashNextMatrixWrite(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	file, err := os.OpenFile(filepath.Clean(path), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	_, writeErr := file.Write(data)
	closeErr := file.Close()
	if writeErr != nil {
		return writeErr
	}
	return closeErr
}
