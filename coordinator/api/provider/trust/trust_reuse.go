package trust

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
const defaultTrustReuseWindow = 5 * time.Minute

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
const defaultTrustReuseReconnectGap = 90 * time.Second
const maxTrustReuseReconnectGap = 120 * time.Second

const clockSkewTolerance = 2 * time.Minute
const trustReuseDeleteAttempts = 3
const (
	trustSafetyJournalHealthReason = "trust_reuse_revocation_journal_unavailable"
	trustSafetyReplayHealthReason  = "trust_reuse_revocation_replay_pending"
)

var trustReuseDeleteRetryBackoff = 200 * time.Millisecond
var trustReuseReplayInitialBackoff = time.Second

type trustReuseDecision string

const (
	trustReuseDecisionSameBinary                trustReuseDecision = "same_binary"
	trustReuseDecisionApprovedReleaseTransition trustReuseDecision = "approved_release_transition"
	// Continuity decisions admit via the connection-continuity premise (the
	// wall-clock window is stale but the coordinator-measured offline gap is
	// within the reconnect-gap allowance). Distinct labels keep both premises
	// observable in logs/metrics.
	trustReuseDecisionContinuity                  trustReuseDecision = "continuity"
	trustReuseDecisionContinuityReleaseTransition trustReuseDecision = "continuity_release_transition"
)

type trustReuseReason string

const (
	trustReuseReasonAllowed              trustReuseReason = "allowed"
	trustReuseReasonMissingIdentity      trustReuseReason = "missing_identity"
	trustReuseReasonNoDeviceEvidence     trustReuseReason = "no_device_evidence"
	trustReuseReasonSerialMismatch       trustReuseReason = "serial_mismatch"
	trustReuseReasonRevoked              trustReuseReason = "durably_revoked"
	trustReuseReasonNotHardware          trustReuseReason = "not_hardware"
	trustReuseReasonRecordedPostureBad   trustReuseReason = "recorded_posture_bad"
	trustReuseReasonProofExpired         trustReuseReason = "hardware_proof_expired"
	trustReuseReasonTransitionUnapproved trustReuseReason = "release_transition_unapproved"
	trustReuseReasonRevocationSafety     trustReuseReason = "revocation_safety_latch"
)

type trustReuseInput struct {
	SEPubKey          string
	Serial            string
	FreshBinaryHash   string
	ReleaseTransition releases.ApprovedTransitionFact
}

type trustReuseResult struct {
	Decision trustReuseDecision
	Reason   trustReuseReason
	Record   trustReuseRecord
}

type trustReuseStore interface {
	ListProviderTrustReuse(ctx context.Context) ([]store.ProviderTrustReuse, error)
	UpsertProviderTrustReuse(ctx context.Context, rec store.ProviderTrustReuse, expectedRevocationGeneration uint64) (store.ProviderTrustReuseWriteResult, error)
	RecoverProviderTrustReuse(ctx context.Context, rec store.ProviderTrustReuse, expectedRevocationGeneration uint64) (store.ProviderTrustReuseWriteResult, error)
	AdvanceProviderTrustReuseCoverage(ctx context.Context, seKeys []string, until time.Time) error
	RevokeProviderTrustReuse(ctx context.Context, seKey, revocationEventID string) (store.ProviderTrustReuse, error)
}

type trustReuseCache struct {
	mu      sync.Mutex
	records map[string]trustReuseRecord

	reuseWindow  time.Duration
	reconnectGap time.Duration
	now          func() time.Time
	store        trustReuseStore
}

type trustReuseRecord struct {
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

func newTrustReuseCache() *trustReuseCache {
	return newTrustReuseCacheWithWindow(trustReuseWindowFromEnv())
}

// newTrustReuseCacheWithWindow pins the fast-skip freshness window verbatim.
// Tests use it to model a specific deployment window; production goes through
// newTrustReuseCache, i.e. the reviewed 5-minute default (Threat-Model #3 /
// T-036: must not span a SIP-disable reboot cycle) or the operator's
// EIGENINFERENCE_TRUST_REUSE_WINDOW override. The continuity reconnect-gap
// allowance always comes from the (hard-clamped) environment default.
func newTrustReuseCacheWithWindow(window time.Duration) *trustReuseCache {
	if window <= 0 {
		window = defaultTrustReuseWindow
	}
	gap, _ := trustReuseReconnectGapFromEnv()
	return &trustReuseCache{
		records:      make(map[string]trustReuseRecord),
		reuseWindow:  window,
		reconnectGap: gap,
		now:          time.Now,
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
	return defaultTrustReuseWindow
}

// trustReuseReconnectGapFromEnv reads EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP
// (a Go duration), falling back to defaultTrustReuseReconnectGap when
// unset/invalid, and hard-clamps the result into [0, maxTrustReuseReconnectGap].
// The 120s ceiling is the RecoveryOS-physics security bound (see the constant
// docs above): values above it clamp DOWN, reported via the second return so
// the caller can log a warning. A zero allowance disables continuity reuse.
func trustReuseReconnectGapFromEnv() (time.Duration, bool) {
	gap := defaultTrustReuseReconnectGap
	if v := os.Getenv("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP"); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			gap = d
		}
	}
	if gap < 0 {
		gap = 0
	}
	if gap > maxTrustReuseReconnectGap {
		return maxTrustReuseReconnectGap, true
	}
	return gap, false
}

func (c *trustReuseCache) decideTrustReuse(input trustReuseInput) trustReuseResult {
	if input.SEPubKey == "" || input.Serial == "" || input.FreshBinaryHash == "" {
		return trustReuseResult{Reason: trustReuseReasonMissingIdentity}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	r, ok := c.records[input.SEPubKey]
	if !ok {
		return trustReuseResult{Reason: trustReuseReasonNoDeviceEvidence}
	}
	if r.serial != input.Serial {
		return trustReuseResult{Reason: trustReuseReasonSerialMismatch}
	}
	if r.revokedAt != nil {
		return trustReuseResult{Reason: trustReuseReasonRevoked}
	}
	if r.trustLevel != string(registry.TrustHardware) {
		return trustReuseResult{Reason: trustReuseReasonNotHardware}
	}
	if !r.sipEnabled || !r.secureBootFull {
		return trustReuseResult{Reason: trustReuseReasonRecordedPostureBad}
	}
	continuity, freshOK := c.freshnessLocked(r)
	if !freshOK {
		return trustReuseResult{Reason: trustReuseReasonProofExpired}
	}
	if r.lastVerifiedBinaryHash == input.FreshBinaryHash {
		decision := trustReuseDecisionSameBinary
		if continuity {
			decision = trustReuseDecisionContinuity
		}
		return trustReuseResult{
			Decision: decision,
			Reason:   trustReuseReasonAllowed,
			Record:   r,
		}
	}
	if _, approvedFrom := input.ReleaseTransition.ApprovedFromBinaryHashes[r.lastVerifiedBinaryHash]; input.ReleaseTransition.Approved && approvedFrom &&
		input.ReleaseTransition.BinaryHash == input.FreshBinaryHash {
		decision := trustReuseDecisionApprovedReleaseTransition
		if continuity {
			decision = trustReuseDecisionContinuityReleaseTransition
		}
		return trustReuseResult{
			Decision: decision,
			Reason:   trustReuseReasonAllowed,
			Record:   r,
		}
	}
	return trustReuseResult{Reason: trustReuseReasonTransitionUnapproved}
}

// freshnessLocked evaluates the two admission premises against the caller's
// record. ok is true when either holds; continuity reports that the record was
// admitted by the connection-continuity premise (wall-clock window stale, but
// the coordinator-measured offline gap now-ContinuousCoverageUntil is within
// the reconnect-gap allowance). A hardware proof dated in the FUTURE beyond
// skew tolerance is corrupt/forged and never admits via either premise.
// Caller holds c.mu.
func (c *trustReuseCache) freshnessLocked(r trustReuseRecord) (continuity, ok bool) {
	now := c.now()
	age := now.Sub(r.hardwareProofVerifiedAt)
	if age < -clockSkewTolerance {
		return false, false
	}
	if age < c.reuseWindow {
		return false, true
	}
	if c.reconnectGap <= 0 || r.continuousCoverageUntil.IsZero() {
		return false, false
	}
	gap := now.Sub(r.continuousCoverageUntil)
	if gap < -clockSkewTolerance || gap > c.reconnectGap {
		return false, false
	}
	return true, true
}

func (c *trustReuseCache) reuseTrust(seKey, serial, freshBinaryHash string, facts ...releases.ApprovedTransitionFact) (trustReuseRecord, bool) {
	var fact releases.ApprovedTransitionFact
	if len(facts) > 0 {
		fact = facts[0]
	}
	result := c.decideTrustReuse(trustReuseInput{
		SEPubKey: seKey, Serial: serial, FreshBinaryHash: freshBinaryHash,
		ReleaseTransition: fact,
	})
	return result.Record, result.Decision != ""
}
func (c *trustReuseCache) hasFreshRecord(seKey, serial string) bool {
	if seKey == "" || serial == "" {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	r, ok := c.records[seKey]
	if !ok || r.serial != serial || r.revokedAt != nil ||
		r.trustLevel != string(registry.TrustHardware) {
		return false
	}
	_, ok = c.freshnessLocked(r)
	return ok
}
