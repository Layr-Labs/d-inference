package protocol

// Autopilot is an explicit, connection-scoped opt-in. Missing snapshots mean
// disabled; protocol negotiation never relies on a provider version string.
const (
	TypeModelAutopilot       = "model_autopilot"
	TypeModelAutopilotStatus = "model_autopilot_status"
	ModelAutopilotProtocol   = 1
)

type ModelAutopilotResident struct {
	ModelID         string   `json:"model_id"`
	ResidentSeconds float64  `json:"resident_seconds"`
	IdleSeconds     float64  `json:"idle_seconds"`
	WeightsGB       float64  `json:"weights_gb"`
	ResidentGB      *float64 `json:"resident_gb,omitempty"`
}

type ModelAutopilotState struct {
	Protocol             int                      `json:"protocol"`
	Enabled              bool                     `json:"enabled"`
	CachedOnly           bool                     `json:"cached_only"`
	MinDwellSeconds      int                      `json:"min_dwell_seconds"`
	PinnedModels         []string                 `json:"pinned_models"`
	MaxModelSlots        int                      `json:"max_model_slots"`
	ResidentModels       []ModelAutopilotResident `json:"resident_models"`
	FreeForLoadNoEvictGB *float64                 `json:"free_for_load_no_evict_gb,omitempty"`
	ActiveCommandID      string                   `json:"active_command_id,omitempty"`
	LastCommandID        string                   `json:"last_command_id,omitempty"`
	LastCommandStatus    string                   `json:"last_command_status,omitempty"`
}

// A command grants permission to unload ONLY the named victims. The provider
// must validate the full resident-set precondition, local work, dwell, pins,
// slot/memory feasibility and expiration before mutating residency. It must
// never invoke implicit LRU eviction to make this operation fit.
type ModelAutopilotMessage struct {
	Type                   string   `json:"type"`
	CommandID              string   `json:"command_id"`
	LoadModelID            string   `json:"load_model_id,omitempty"`
	UnloadModelIDs         []string `json:"unload_model_ids"`
	ExpectedResidentModels []string `json:"expected_resident_models"`
	ExpiresAtMS            int64    `json:"expires_at_ms"`
	LeaseSeconds           int      `json:"lease_seconds"`
}

// Status is an acknowledgement, not authoritative scheduler capacity. Only a
// fresh sequenced heartbeat can reconcile the resulting BackendCapacity slots.
type ModelAutopilotStatusMessage struct {
	Type           string               `json:"type"`
	CommandID      string               `json:"command_id"`
	Status         string               `json:"status"`
	Error          string               `json:"error,omitempty"`
	ModelAutopilot *ModelAutopilotState `json:"model_autopilot,omitempty"`
}
