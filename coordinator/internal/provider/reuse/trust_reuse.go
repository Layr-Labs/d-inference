package reuse

import (
	"context"
	"os"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/releases"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// defaultTrustReuseWindow is how long a successful FULL live MDM verification is
// honored for a NEW connection from the same device — without re-running the live
// MDM SecurityInfo round-trip — provided a fresh live SE challenge re-proves the
// SAME identity, binary, and good posture. It bounds the staleness of the MDM
// proof. Kept SHORT (Threat-Model #3): the reuse must not be able to span a
// SIP-disable reboot cycle (where a box reboots into Recovery, disables SIP, and
// reconnects), so a window comfortably under a realistic reboot+reconnect is used.
// Tightened from 10m to 5m once connection-continuity reuse (see
// trustReuseReconnectGapFromEnv) started covering the legitimate operational
// reconnect cases, so the pure wall-clock staleness bound can be stricter.
// Overridable via EIGENINFERENCE_TRUST_REUSE_WINDOW.
const DefaultWindow = 5 * time.Minute

// Connection-continuity reuse (the "continuity" decision): a provider that was
// live-verified, stayed continuously connected and hardware-trusted (the
// coordinator advances a durable ContinuousCoverageUntil watermark while it
// observes the live SE-challenged connection), and reconnects after a
// coordinator-MEASURED offline gap of at most the reconnect-gap allowance may
// reuse its device evidence even when HardwareProofVerifiedAt has fallen out
// of the wall-clock window. SECURITY INVARIANT (Threat-Model T-036):
// SIP/Secure Boot can only change in RecoveryOS; entering and leaving Recovery
// on Apple Silicon (One True Recovery: manual power-button entry, credentialed
// csrutil/bputil, two boot transitions) takes >= ~3 minutes and drops any
// WebSocket, so a contiguous coordinator-measured offline gap <= 120s cannot
// span a posture flip. The gap is never provider-claimed. The 120s ceiling is
// therefore a HARD security bound: EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP
// values above it clamp DOWN (with a warning), never up.
const DefaultReconnectGap = 90 * time.Second
const MaxTrustReuseReconnectGap = 120 * time.Second

const ClockSkewTolerance = 2 * time.Minute
const TrustReuseDeleteAttempts = 3
const (
	TrustSafetyJournalHealthReason = "trust_reuse_revocation_journal_unavailable"
	TrustSafetyReplayHealthReason  = "trust_reuse_revocation_replay_pending"
)

const TrustReuseDeleteRetryBackoff = 200 * time.Millisecond
const TrustReuseReplayInitialBackoff = time.Second

type Decision string

const (
	SameBinary                Decision = "same_binary"
	ApprovedReleaseTransition Decision = "approved_release_transition"
	// Continuity decisions admit via the connection-continuity premise (the
	// wall-clock window is stale but the coordinator-measured offline gap is
	// within the reconnect-gap allowance). Distinct labels keep both premises
	// observable in logs/metrics.
	Continuity                  Decision = "continuity"
	ContinuityReleaseTransition Decision = "continuity_release_transition"
)

type Reason string

const (
	TrustReuseReasonAllowed              Reason = "allowed"
	TrustReuseReasonMissingIdentity      Reason = "missing_identity"
	TrustReuseReasonNoDeviceEvidence     Reason = "no_device_evidence"
	trustReuseReasonSerialMismatch       Reason = "serial_mismatch"
	TrustReuseReasonRevoked              Reason = "durably_revoked"
	trustReuseReasonNotHardware          Reason = "not_hardware"
	TrustReuseReasonRecordedPostureBad   Reason = "recorded_posture_bad"
	ProofExpired                         Reason = "hardware_proof_expired"
	TrustReuseReasonTransitionUnapproved Reason = "release_transition_unapproved"
	TrustReuseReasonRevocationSafety     Reason = "revocation_safety_latch"
)

type Input struct {
	SEPubKey          string
	Serial            string
	FreshBinaryHash   string
	ReleaseTransition releases.ApprovedTransitionFact
}

type Result struct {
	Decision Decision
	Reason   Reason
	Record   Record
}

type Store interface {
	ListProviderTrustReuse(ctx context.Context) ([]store.ProviderTrustReuse, error)
	UpsertProviderTrustReuse(ctx context.Context, rec store.ProviderTrustReuse, expectedRevocationGeneration uint64) (store.ProviderTrustReuseWriteResult, error)
	RecoverProviderTrustReuse(ctx context.Context, rec store.ProviderTrustReuse, expectedRevocationGeneration uint64) (store.ProviderTrustReuseWriteResult, error)
	AdvanceProviderTrustReuseCoverage(ctx context.Context, seKeys []string, until time.Time) error
	RevokeProviderTrustReuse(ctx context.Context, seKey, RevocationEventID string) (store.ProviderTrustReuse, error)
}

type Cache struct {
	*Policy
	mu                    sync.Mutex
	publicationGeneration uint64
	records               map[string]Record
	Store                 Store
}

// trustReusePolicy is the deployment's measured-gap and wall-clock policy.
// It is fixed before verification starts; Now is shared with coverage stamping.
type Policy struct {
	Window       time.Duration
	ReconnectGap time.Duration
	Now          func() time.Time
}

type Record struct {
	Serial                     string
	TrustLevel                 string
	LastVerifiedBinaryHash     string
	SipEnabled                 bool
	SecureBootFull             bool
	MdaUDID                    string
	HardwareProofVerifiedAt    time.Time
	ContinuousCoverageUntil    time.Time
	ApplicationProofVerifiedAt *time.Time
	EvidenceGeneration         uint64
	RevocationGeneration       uint64
	RevocationEventID          string
	revokedAt                  *time.Time
}

func New() *Cache {
	return NewWithWindow(trustReuseWindowFromEnv())
}

// newTrustReuseCacheWithWindow pins the fast-skip freshness window verbatim.
// Tests use it to model a specific deployment window; production goes through
// newTrustReuseCache, i.e. the reviewed 5-minute default (Threat-Model #3 /
// T-036: must not span a SIP-disable reboot cycle) or the operator's
// EIGENINFERENCE_TRUST_REUSE_WINDOW override. The continuity reconnect-gap
// allowance always comes from the (hard-clamped) environment default.
func NewWithWindow(window time.Duration) *Cache {
	if window <= 0 {
		window = DefaultWindow
	}
	gap, _ := TrustReuseReconnectGapFromEnv()
	return &Cache{
		records: make(map[string]Record),
		Policy: &Policy{
			Window: window, ReconnectGap: gap, Now: time.Now,
		},
	}
}

// trustReuseWindowFromEnv reads EIGENINFERENCE_TRUST_REUSE_WINDOW (a Go duration,
// e.g. "45m"), falling back to defaultTrustReuseWindow when unset/invalid.
func trustReuseWindowFromEnv() time.Duration {
	if v := os.Getenv("EIGENINFERENCE_TRUST_REUSE_WINDOW"); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			return d
		}
	}
	return DefaultWindow
}

// trustReuseReconnectGapFromEnv reads EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP
// (a Go duration), falling back to defaultTrustReuseReconnectGap when
// unset/invalid, and hard-clamps the result into [0, maxTrustReuseReconnectGap].
// The 120s ceiling is the RecoveryOS-physics security bound (see the constant
// docs above): values above it clamp DOWN, reported via the second return so
// the caller can log a warning. A zero allowance disables continuity reuse.
func TrustReuseReconnectGapFromEnv() (time.Duration, bool) {
	gap := DefaultReconnectGap
	if v := os.Getenv("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP"); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			gap = d
		}
	}
	if gap < 0 {
		gap = 0
	}
	if gap > MaxTrustReuseReconnectGap {
		return MaxTrustReuseReconnectGap, true
	}
	return gap, false
}

func (c *Cache) Decide(input Input) Result {
	if input.SEPubKey == "" || input.Serial == "" || input.FreshBinaryHash == "" {
		return Result{Reason: TrustReuseReasonMissingIdentity}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	r, ok := c.records[input.SEPubKey]
	if !ok {
		return Result{Reason: TrustReuseReasonNoDeviceEvidence}
	}
	if r.Serial != input.Serial {
		return Result{Reason: trustReuseReasonSerialMismatch}
	}
	if r.revokedAt != nil {
		return Result{Reason: TrustReuseReasonRevoked}
	}
	if r.TrustLevel != string(registry.TrustHardware) {
		return Result{Reason: trustReuseReasonNotHardware}
	}
	if !r.SipEnabled || !r.SecureBootFull {
		return Result{Reason: TrustReuseReasonRecordedPostureBad}
	}
	continuity, freshOK := c.freshnessLocked(r)
	if !freshOK {
		return Result{Reason: ProofExpired}
	}
	if r.LastVerifiedBinaryHash == input.FreshBinaryHash {
		decision := SameBinary
		if continuity {
			decision = Continuity
		}
		return Result{
			Decision: decision,
			Reason:   TrustReuseReasonAllowed,
			Record:   r,
		}
	}
	if _, approvedFrom := input.ReleaseTransition.ApprovedFromBinaryHashes[r.LastVerifiedBinaryHash]; input.ReleaseTransition.Approved && approvedFrom &&
		input.ReleaseTransition.BinaryHash == input.FreshBinaryHash {
		decision := ApprovedReleaseTransition
		if continuity {
			decision = ContinuityReleaseTransition
		}
		return Result{
			Decision: decision,
			Reason:   TrustReuseReasonAllowed,
			Record:   r,
		}
	}
	return Result{Reason: TrustReuseReasonTransitionUnapproved}
}

// freshnessLocked evaluates the two admission premises against the caller's
// record. ok is true when either holds; continuity reports that the record was
// admitted by the connection-continuity premise (wall-clock window stale, but
// the coordinator-measured offline gap now-ContinuousCoverageUntil is within
// the reconnect-gap allowance). A hardware proof dated in the FUTURE beyond
// skew tolerance is corrupt/forged and never admits via either premise.
// Caller holds c.mu.
func (c *Cache) freshnessLocked(r Record) (continuity, ok bool) {
	Now := c.Now()
	age := Now.Sub(r.HardwareProofVerifiedAt)
	if age < -ClockSkewTolerance {
		return false, false
	}
	if age < c.Window {
		return false, true
	}
	if c.ReconnectGap <= 0 || r.ContinuousCoverageUntil.IsZero() {
		return false, false
	}
	gap := Now.Sub(r.ContinuousCoverageUntil)
	if gap < -ClockSkewTolerance || gap > c.ReconnectGap {
		return false, false
	}
	return true, true
}

func (c *Cache) HasFreshRecord(seKey, Serial string) bool {
	if seKey == "" || Serial == "" {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	r, ok := c.records[seKey]
	if !ok || r.Serial != Serial || r.revokedAt != nil ||
		r.TrustLevel != string(registry.TrustHardware) {
		return false
	}
	_, ok = c.freshnessLocked(r)
	return ok
}
