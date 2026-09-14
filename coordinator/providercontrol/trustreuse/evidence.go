package trustreuse

import (
	"github.com/eigeninference/d-inference/coordinator/store"
	"sync"
	"time"
)

type Decision string

const (
	DecisionSameBinary                Decision = "same_binary"
	DecisionApprovedReleaseTransition Decision = "approved_release_transition"
	// Continuity decisions admit via the connection-continuity premise (the
	// wall-clock window is stale but the coordinator-measured offline gap is
	// within the reconnect-gap allowance). Distinct labels keep both premises
	// observable in logs/metrics.
	DecisionContinuity                  Decision = "continuity"
	DecisionContinuityReleaseTransition Decision = "continuity_release_transition"
)

type Reason string

const (
	ReasonAllowed              Reason = "allowed"
	ReasonMissingIdentity      Reason = "missing_identity"
	ReasonNoDeviceEvidence     Reason = "no_device_evidence"
	ReasonSerialMismatch       Reason = "serial_mismatch"
	ReasonRevoked              Reason = "durably_revoked"
	ReasonNotHardware          Reason = "not_hardware"
	ReasonRecordedPostureBad   Reason = "recorded_posture_bad"
	ReasonProofExpired         Reason = "hardware_proof_expired"
	ReasonTransitionUnapproved Reason = "release_transition_unapproved"
	ReasonRevocationSafety     Reason = "revocation_safety_latch"
)

type ReleaseTransition struct {
	Approved                 bool
	BinaryHash               string
	Version                  string
	Platform                 string
	Backend                  string
	PolicyGeneration         uint64
	ApprovedFromBinaryHashes map[string]struct{}
}

type Input struct {
	SEPubKey          string
	Serial            string
	FreshBinaryHash   string
	ReleaseTransition ReleaseTransition
}

type result struct {
	Decision Decision
	Reason   Reason
	Record   record
}

type cache struct {
	mu      sync.Mutex
	records map[string]record

	reuseWindow  time.Duration
	reconnectGap time.Duration
	now          func() time.Time
	store        Store
}

type record struct {
	serial                     string
	trustLevel                 string
	lastVerifiedBinaryHash     string
	sipEnabled                 bool
	secureBootFull             bool
	mdaUDID                    string
	hardwareProofVerifiedAt    time.Time
	continuousCoverageUntil    time.Time
	applicationProofVerifiedAt *time.Time
	evidenceGeneration         uint64
	revocationGeneration       uint64
	revocationEventID          string
	revokedAt                  *time.Time
}

func trustReuseRecordFromStore(rec store.ProviderTrustReuse) record {
	return record{
		serial:                     rec.Serial,
		trustLevel:                 rec.TrustLevel,
		lastVerifiedBinaryHash:     rec.LastVerifiedBinaryHash,
		sipEnabled:                 rec.SIPEnabled,
		secureBootFull:             rec.SecureBootFull,
		mdaUDID:                    rec.MDAUDID,
		hardwareProofVerifiedAt:    rec.HardwareProofVerifiedAt,
		applicationProofVerifiedAt: rec.ApplicationProofVerifiedAt,
		continuousCoverageUntil:    coverageFromStore(rec.ContinuousCoverageUntil),
		evidenceGeneration:         rec.EvidenceGeneration,
		revocationGeneration:       rec.RevocationGeneration,
		revocationEventID:          rec.RevocationEventID,
		revokedAt:                  rec.RevokedAt,
	}
}

func coverageFromStore(until *time.Time) time.Time {
	if until == nil {
		return time.Time{}
	}
	return *until
}

func coverageToStore(until time.Time) *time.Time {
	if until.IsZero() {
		return nil
	}
	return &until
}

// CoverageFromStore preserves absent continuity watermarks as zero time.
func CoverageFromStore(until *time.Time) time.Time { return coverageFromStore(until) }
