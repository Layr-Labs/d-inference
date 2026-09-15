package api

import (
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func appAttestHardwareComparison(version int, s *protocol.AppAttestStatus, h protocol.Hardware) (known, matched bool) {
	if version != 3 || s == nil {
		return false, false
	}
	for _, value := range s.HardwareValues() {
		if value == "" {
			return false, false
		}
	}
	if h.MachineModel == "" || h.MemoryGB <= 0 || h.CPUCores.Total <= 0 || h.GPUCores <= 0 {
		return false, false
	}
	return true, s.MachineModel == h.MachineModel && s.Chip == h.ChipName &&
		s.MemoryGB == strconv.Itoa(h.MemoryGB) && s.CPUTotal == strconv.Itoa(h.CPUCores.Total) &&
		s.CPUPerformance == strconv.Itoa(h.CPUCores.Performance) && s.CPUEfficiency == strconv.Itoa(h.CPUCores.Efficiency) && s.GPUCores == strconv.Itoa(h.GPUCores)
}
