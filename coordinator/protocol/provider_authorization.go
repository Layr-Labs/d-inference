package protocol

// ProviderServingAuthorization is coordinator-derived operator guidance. It is
// never accepted from a provider and never substitutes for dispatch validation.
type ProviderServingAuthorization struct {
	Protocol           int    `json:"protocol"`
	AppAttestAvailable bool   `json:"app_attest_available"`
	Path               string `json:"path"`
	ExpiresAt          int64  `json:"expires_at,omitempty"`
	MDMRemovalReady    bool   `json:"mdm_removal_ready"`
	Reason             string `json:"reason"`
	SessionID          string `json:"session_id"`
	MachineID          string `json:"machine_id,omitempty"`
}
