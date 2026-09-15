package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
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
	AccountID        string    `json:"account_id"`
	SEKey            string    `json:"-"` // authenticated legacy key; not proof of physical uniqueness
	VerifiedSerial   string    `json:"-"` // only fresh, SE-bound Apple MDA evidence
	At               time.Time `json:"observed_at"`
	Disconnected     bool      `json:"disconnected"`
	DisconnectReason string    `json:"disconnect_reason,omitempty"`
	OSVersion        string    `json:"os_version"`
	OSMajor          int       `json:"os_major"`
	OSBuild          string    `json:"os_build"`
	Version          string    `json:"version"`
	Chip             string    `json:"chip"`
	MemoryGB         float64   `json:"memory_gb"`
	Protocol         int       `json:"protocol"`
	ShadowEnabled    bool      `json:"shadow_enabled"`
	LegacyTrust      string    `json:"legacy_trust"`
	LegacyCode       bool      `json:"legacy_code"`
	LegacyMDA        bool      `json:"legacy_mda"`
}

const inventoryStaleDisconnectReason = "inventory_stale"

// A delayed capture cannot overwrite newer liveness or reopen a confirmed
// disconnect. A fresh capture may revive a closure inferred from stale data.
func inventoryObservationSuperseded(lastSeen time.Time, disconnected bool, reason string, next MachineObservation) bool {
	return next.At.Before(lastSeen) || disconnected && (reason != inventoryStaleDisconnectReason || !next.At.After(lastSeen))
}

type machineAlias struct{ Kind, Scope, Digest string }

func (o MachineObservation) aliases() []machineAlias {
	var aliases []machineAlias
	add := func(kind, scope, value string) {
		h := sha256.Sum256([]byte(kind + "\x00" + value))
		aliases = append(aliases, machineAlias{kind, scope, hex.EncodeToString(h[:])})
	}
	// A serial claim never enters this list. Anonymous observations remain
	// provisional; they cannot acquire another account's aliases.
	if o.AccountID != "" && o.SEKey != "" {
		if o.VerifiedSerial != "" {
			add("mda_serial", "", o.VerifiedSerial)
		}
		add("legacy_se", o.AccountID, o.SEKey)
	}
	return aliases
}

func (o MachineObservation) assurance() string {
	if len(o.aliases()) == 0 {
		return "provisional"
	}
	if o.VerifiedSerial != "" {
		return "hardware_verified"
	}
	return "key_bound"
}

type AppAttestEvent struct {
	ID        string          `json:"id"`
	SessionID string          `json:"session_id"`
	At        time.Time       `json:"at"`
	Stage     string          `json:"stage"`
	Outcome   string          `json:"outcome"`
	Fields    json.RawMessage `json:"fields"`
}

func strongerAssurance(a, b string) string {
	if a == "" {
		return b
	}
	rank := map[string]int{"provisional": 0, "key_bound": 1, "hardware_verified": 2}
	if rank[b] > rank[a] {
		return b
	}
	return a
}
