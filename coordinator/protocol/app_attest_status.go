package protocol

// These are app-derived claims, authenticated by an assertion, not measurements
// independently certified by Apple. Keep the field order mirrored in Swift.
type AppAttestStatus struct {
	AttestationPublicKey string `json:"attestation_public_key,omitempty"`
	MachineModel         string `json:"machine_model,omitempty"`
	MemoryGB             string `json:"memory_gb,omitempty"`
	CPUTotal             string `json:"cpu_total,omitempty"`
	CPUPerformance       string `json:"cpu_performance,omitempty"`
	CPUEfficiency        string `json:"cpu_efficiency,omitempty"`
	GPUCores             string `json:"gpu_cores,omitempty"`
	OSVersion            string `json:"os_version"`
	OSBuild              string `json:"os_build"`
	AppVersion           string `json:"app_version"`
	Chip                 string `json:"chip"`
	BinaryHash           string `json:"binary_hash"`
}

func (s *AppAttestStatus) Values() []string {
	if s == nil {
		return []string{"", "", "", "", ""}
	}
	return []string{s.OSVersion, s.OSBuild, s.AppVersion, s.Chip, s.BinaryHash}
}
