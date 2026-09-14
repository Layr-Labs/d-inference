package protocol

// RuntimeStatusMessage is sent by the coordinator to inform a provider about
// the result of its runtime integrity verification. If mismatches are found,
// the provider can self-heal (e.g. re-download corrupted files).
type RuntimeStatusMessage struct {
	Type       string            `json:"type"`
	Verified   bool              `json:"verified"`
	Mismatches []RuntimeMismatch `json:"mismatches,omitempty"`
}

// RuntimeMismatch describes a single component whose hash did not match
// the coordinator's known-good manifest.
type RuntimeMismatch struct {
	Component string `json:"component"`
	Expected  string `json:"expected"`
	Got       string `json:"got"`
}

// TrustStatusMessage is sent by the coordinator to inform a provider of its
// current trust level for local operator diagnostics.
type TrustStatusMessage struct {
	Type       string `json:"type"`
	TrustLevel string `json:"trust_level"` // "none", "self_signed", "hardware"
	Status     string `json:"status"`      // "online", "untrusted", etc.
	Reason     string `json:"reason,omitempty"`
}
