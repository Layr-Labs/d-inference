package trustreuse

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"github.com/google/uuid"
	"strings"
)

// hardUntrustJournalEntry is one durable pending hard-untrust revocation.
// SEPubKey (added within journal version 1 as an optional field) carries the
// plaintext SE public key so crash replay can create a missing tombstone row
// even when the identity never had a provider_trust_reuse row at revocation
// time. Legacy digest-only entries (written before the field existed) still
// load and replay against listed rows; only row-less convergence needs the key.
type hardUntrustJournalEntry struct {
	Version      int    `json:"v"`
	SEKeySHA256  string `json:"se_key_sha256"`
	RevocationID string `json:"revocation_event_id"`
	SEPubKey     string `json:"se_pub_key,omitempty"`
}

type hardUntrustJournal interface {
	Initialize() error
	Load() ([]hardUntrustJournalEntry, error)
	Append(hardUntrustJournalEntry) ([]hardUntrustJournalEntry, error)
	Remove(hardUntrustJournalEntry) ([]hardUntrustJournalEntry, error)
	Path() string
}

func hashSEPublicKey(seKey string) string {
	digest := sha256.Sum256([]byte(seKey))
	return hex.EncodeToString(digest[:])
}

func newHardUntrustJournalEntry(seKey, revocationEventID string) hardUntrustJournalEntry {
	return hardUntrustJournalEntry{
		Version:      trustReuseJournalVersion,
		SEKeySHA256:  hashSEPublicKey(seKey),
		RevocationID: revocationEventID,
		SEPubKey:     seKey,
	}
}

func validateHardUntrustJournalEntry(entry hardUntrustJournalEntry) error {
	if entry.Version != trustReuseJournalVersion {
		return fmt.Errorf("unsupported journal version %d", entry.Version)
	}
	if len(entry.SEKeySHA256) != sha256.Size*2 || strings.ToLower(entry.SEKeySHA256) != entry.SEKeySHA256 {
		return errors.New("invalid SE key digest")
	}
	if _, err := hex.DecodeString(entry.SEKeySHA256); err != nil {
		return errors.New("invalid SE key digest")
	}
	parsed, err := uuid.Parse(entry.RevocationID)
	if err != nil || parsed.String() != entry.RevocationID {
		return errors.New("invalid revocation event ID")
	}
	// Optional plaintext SE key (row-less replay) must bind to the digest, so
	// a corrupted/edited journal line cannot redirect a revocation replay.
	if entry.SEPubKey != "" && hashSEPublicKey(entry.SEPubKey) != entry.SEKeySHA256 {
		return errors.New("SE key does not match digest")
	}
	return nil
}
