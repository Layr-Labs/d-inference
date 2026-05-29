package store

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"time"
)

// KeyPrefix is the brand prefix for every consumer API key minted by the
// coordinator. The legacy prefix was "eigeninference-"; existing keys with that
// prefix remain valid (lookups are by hash, not prefix) — only newly minted
// keys carry this prefix.
const KeyPrefix = "sk-db-"

// keyRandomBytes is the number of random bytes in the secret portion of a key.
const keyRandomBytes = 32

// GenerateRawKey returns a fresh cryptographically random raw API key of the
// form "sk-db-<64 hex chars>". The raw key is only ever available at creation;
// stores persist a hash, never the plaintext.
func GenerateRawKey() (string, error) {
	b := make([]byte, keyRandomBytes)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return KeyPrefix + hex.EncodeToString(b), nil
}

// GenerateKeyID returns a stable, non-secret public identifier for a key,
// of the form "key_<24 hex chars>". Used for management endpoints and per-key
// usage/spend attribution.
func GenerateKeyID() (string, error) {
	b := make([]byte, 12)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return "key_" + hex.EncodeToString(b), nil
}

// LegacyAccountID derives a stable, NON-SECRET account identity for an unlinked
// legacy API key (one with no owner account). Hashing the raw key keeps the
// secret out of ledger references, balances.account_id, and logs while still
// giving the key a consistent identity across requests. The "legacy:" prefix
// namespaces it so it can never collide with a real Privy account ID.
func LegacyAccountID(rawKey string) string {
	h := sha256.Sum256([]byte(rawKey))
	return "legacy:" + hex.EncodeToString(h[:])
}

// KeyLabel returns a masked display label for a raw key showing the brand
// prefix, the first few characters, and the last four — e.g.
// "sk-db-1a2b…c3d4". Safe to store and show; reveals nothing usable.
func KeyLabel(raw string) string {
	const head = len(KeyPrefix) + 4 // brand prefix + 4 chars of entropy
	if len(raw) <= head+4 {
		// Too short to mask meaningfully; fall back to a head-only prefix.
		if len(raw) <= 6 {
			return raw
		}
		return raw[:6] + "..."
	}
	return raw[:head] + "..." + raw[len(raw)-4:]
}

// NormalizeResetWindow returns a valid reset-window value, defaulting unknown
// or empty inputs to KeyResetNone (a lifetime cap).
func NormalizeResetWindow(reset string) string {
	switch reset {
	case KeyResetDaily, KeyResetWeekly, KeyResetMonthly:
		return reset
	default:
		return KeyResetNone
	}
}

// KeySpendWindowStart returns the UTC instant at which the current spend window
// for the given reset cadence began. For KeyResetNone (lifetime) it returns the
// zero time, meaning "sum all spend". Daily/weekly/monthly align to UTC
// calendar boundaries (midnight UTC; weeks start Monday; months on the 1st).
func KeySpendWindowStart(reset string, now time.Time) time.Time {
	now = now.UTC()
	switch reset {
	case KeyResetDaily:
		return time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	case KeyResetWeekly:
		// Monday is the start of the week. Go's Weekday() has Sunday=0.
		offset := (int(now.Weekday()) + 6) % 7 // days since Monday
		monday := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
		return monday.AddDate(0, 0, -offset)
	case KeyResetMonthly:
		return time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	default:
		return time.Time{}
	}
}
