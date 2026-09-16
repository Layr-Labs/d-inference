package contracts

import (
	"context"
	"encoding/json"
	"time"
)

// MachineInventoryStore is an additive observation model. A machine ID never
// authorizes a connection, changes a ledger key, or replaces live verification.
type MachineInventoryStore interface {
	ObserveMachine(context.Context, MachineObservation) (MachineIdentity, error)
	RecordAppAttestEvent(context.Context, AppAttestEvent) error
}

type MachineIdentity struct {
	ID        string `json:"machine_id"`
	Assurance string `json:"assurance"`
}

type MachineObservation struct {
	OSSource      string    `json:"os_source"`
	OSObservedAt  time.Time `json:"os_observed_at"`
	ShadowDropped uint64    `json:"shadow_dropped"`
	Source        string    `json:"source"`
	SessionID     string    `json:"session_id"`
	// AccountID must come from this registration's validated provider token,
	// never an account restored by a claimed serial or supplied machine UUID.
	AccountID            string    `json:"account_id"`
	SEKey                string    `json:"-"` // authenticated legacy key; not proof of physical uniqueness
	VerifiedSerial       string    `json:"-"` // only fresh, SE-bound Apple MDA evidence
	VerifiedAppAttestKey string    `json:"-"` // set only after a fresh endpoint-bound assertion commits
	At                   time.Time `json:"observed_at"`
	Disconnected         bool      `json:"disconnected"`
	DisconnectReason     string    `json:"disconnect_reason,omitempty"`
	OSVersion            string    `json:"os_version"`
	OSMajor              int       `json:"os_major"`
	OSBuild              string    `json:"os_build"`
	Version              string    `json:"version"`
	Chip                 string    `json:"chip"`
	MemoryGB             float64   `json:"memory_gb"`
	Protocol             int       `json:"protocol"`
	ShadowEnabled        bool      `json:"shadow_enabled"`
	LegacyTrust          string    `json:"legacy_trust"`
	LegacyCode           bool      `json:"legacy_code"`
	LegacyMDA            bool      `json:"legacy_mda"`
}

type AppAttestEvent struct {
	ID        string          `json:"id"`
	SessionID string          `json:"session_id"`
	At        time.Time       `json:"at"`
	Stage     string          `json:"stage"`
	Outcome   string          `json:"outcome"`
	Fields    json.RawMessage `json:"fields"`
}
