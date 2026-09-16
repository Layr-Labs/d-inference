package inventoryrecord

import (
	"crypto/sha256"
	"encoding/hex"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

const StaleDisconnectReason = "inventory_stale"

// A delayed capture cannot overwrite newer liveness or reopen a confirmed
// disconnect. A fresh capture may revive a closure inferred from stale data.
func ObservationSuperseded(lastSeen time.Time, disconnected bool, reason string, next contracts.MachineObservation) bool {
	return next.At.Before(lastSeen) || disconnected && (reason != StaleDisconnectReason || !next.At.After(lastSeen))
}

type Alias struct{ Kind, Scope, Digest string }

func Aliases(o contracts.MachineObservation) []Alias {
	var aliases []Alias
	add := func(kind, scope, value string) {
		h := sha256.Sum256([]byte(kind + "\x00" + value))
		aliases = append(aliases, Alias{kind, scope, hex.EncodeToString(h[:])})
	}
	// A serial claim never enters this list. Anonymous observations remain
	// provisional; they cannot acquire another account's aliases.
	if o.AccountID != "" {
		if o.SEKey != "" && o.VerifiedSerial != "" {
			add("mda_serial", "", o.VerifiedSerial)
		}
		if o.VerifiedAppAttestKey != "" {
			add("app_attest", o.AccountID, o.VerifiedAppAttestKey)
		}
		if o.SEKey != "" {
			add("legacy_se", o.AccountID, o.SEKey)
		}
	}
	return aliases
}

func Assurance(o contracts.MachineObservation) string {
	if len(Aliases(o)) == 0 {
		return "provisional"
	}
	if o.AccountID != "" && o.SEKey != "" && o.VerifiedSerial != "" {
		return "hardware_verified"
	}
	return "key_bound"
}

func StrongerAssurance(a, b string) string {
	if a == "" {
		return b
	}
	rank := map[string]int{"provisional": 0, "key_bound": 1, "hardware_verified": 2}
	if rank[b] > rank[a] {
		return b
	}
	return a
}
