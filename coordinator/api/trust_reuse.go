package api

import (
	"context"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
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

type approvedReleaseTransitionFact struct {
	Approved                 bool
	BinaryHash               string
	Version                  string
	Platform                 string
	Backend                  string
	PolicyGeneration         uint64
	ApprovedFromBinaryHashes map[string]struct{}
}

type trustReuseInput struct {
	SEPubKey          string
	Serial            string
	FreshBinaryHash   string
	ReleaseTransition approvedReleaseTransitionFact
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

func (c *trustReuseCache) reuseTrust(seKey, serial, freshBinaryHash string, facts ...approvedReleaseTransitionFact) (trustReuseRecord, bool) {
	var fact approvedReleaseTransitionFact
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

func trustReuseRecordFromStore(rec store.ProviderTrustReuse) trustReuseRecord {
	return trustReuseRecord{
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

// advanceCoverage moves the in-memory continuity watermark forward for the
// given identities. Mirrors the store's monotonic guard: never backward, never
// on a tombstoned or non-hardware record.
func (c *trustReuseCache) advanceCoverage(seKeys []string, until time.Time) {
	if until.IsZero() {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, seKey := range seKeys {
		r, ok := c.records[seKey]
		if !ok || r.revokedAt != nil ||
			r.trustLevel != string(registry.TrustHardware) ||
			!until.After(r.continuousCoverageUntil) {
			continue
		}
		r.continuousCoverageUntil = until
		c.records[seKey] = r
	}
}

func (c *trustReuseCache) recordTrust(rec store.ProviderTrustReuse) {
	if rec.SEPubKey == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if current, ok := c.records[rec.SEPubKey]; ok {
		if current.revokedAt != nil ||
			current.revocationGeneration != rec.RevocationGeneration {
			return
		}
	}
	c.records[rec.SEPubKey] = trustReuseRecordFromStore(rec)
}

func (c *trustReuseCache) recoverTrust(rec store.ProviderTrustReuse, expectedRevocationGeneration uint64) bool {
	if rec.SEPubKey == "" {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if current, ok := c.records[rec.SEPubKey]; ok &&
		current.revocationGeneration != expectedRevocationGeneration {
		return false
	}
	rec.RevocationGeneration = expectedRevocationGeneration
	rec.RevokedAt = nil
	c.records[rec.SEPubKey] = trustReuseRecordFromStore(rec)
	return true
}

func (c *trustReuseCache) revocationState(seKey string) (uint64, string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	rec := c.records[seKey]
	return rec.revocationGeneration, rec.revocationEventID
}

func (c *trustReuseCache) isRevoked(seKey string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	rec, ok := c.records[seKey]
	return ok && rec.revokedAt != nil
}

func (c *trustReuseCache) invalidateReuse(seKey, revocationEventID string) uint64 {
	if seKey == "" || revocationEventID == "" {
		return 0
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	rec := c.records[seKey]
	if rec.revocationEventID == revocationEventID {
		return rec.revocationGeneration
	}
	rec.trustLevel = ""
	rec.revocationGeneration++
	rec.revocationEventID = revocationEventID
	now := c.now().UTC()
	rec.revokedAt = &now
	c.records[seKey] = rec
	return rec.revocationGeneration
}

func (c *trustReuseCache) installRevocationGeneration(seKey string, generation uint64) {
	if seKey == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	rec := c.records[seKey]
	if rec.revocationGeneration > generation {
		return
	}
	rec.trustLevel = ""
	rec.revocationGeneration = generation
	now := c.now().UTC()
	rec.revokedAt = &now
	c.records[seKey] = rec
}

func (c *trustReuseCache) installAuthoritativeTrustReuse(rec store.ProviderTrustReuse) {
	if rec.SEPubKey == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	current := c.records[rec.SEPubKey]
	if current.revocationGeneration > rec.RevocationGeneration {
		return
	}
	c.records[rec.SEPubKey] = trustReuseRecordFromStore(rec)
}

// seed installs persisted rows into the cache at startup. Every keyed row is
// RETAINED — including rows whose freshness has lapsed — because a row's
// RevocationGeneration is durable CAS state, not just reuse evidence: dropping
// an expired row for a previously-revoked-then-recovered device would make the
// next full live MDM grant submit expected generation zero, lose the recovery
// CAS against the durable row, and be misclassified as a transient failure
// (Codex P1). Staleness never grants anything: decideTrustReuse and
// hasFreshRecord re-run the freshness/continuity gates on every read, so a
// retained expired/future-dated row is pure generation state. The return value
// counts only rows currently admissible for reuse (logging).
func (c *trustReuseCache) seed(rows []store.ProviderTrustReuse) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := 0
	for _, row := range rows {
		if row.SEPubKey == "" {
			continue
		}
		incoming := trustReuseRecordFromStore(row)
		current, ok := c.records[row.SEPubKey]
		if ok && current.revocationGeneration > incoming.revocationGeneration {
			continue
		}
		if ok && current.revocationGeneration == incoming.revocationGeneration {
			if current.revokedAt != nil {
				continue
			}
			if !incoming.hardwareProofVerifiedAt.After(current.hardwareProofVerifiedAt) {
				continue
			}
		}
		c.records[row.SEPubKey] = incoming
		if incoming.revokedAt == nil {
			if _, admissible := c.freshnessLocked(incoming); admissible {
				n++
			}
		}
	}
	return n
}

func (s *Server) latchTrustSafety(err error) {
	if s == nil {
		return
	}
	s.trustSafetyMu.Lock()
	s.trustSafetySticky = true
	s.trustSafetyMu.Unlock()
	if s.logger != nil {
		s.logger.Error("trust-reuse safety latch engaged",
			"health_reason", trustSafetyJournalHealthReason,
			"error", err,
		)
	}
}

func (s *Server) setTrustReplayBlocked(blocked bool) {
	if s == nil {
		return
	}
	s.trustSafetyMu.Lock()
	s.trustSafetyReplayBlocked = blocked
	s.trustSafetyMu.Unlock()
}

func (s *Server) trustSafetyStatus() (bool, string) {
	if s == nil {
		return false, ""
	}
	s.trustSafetyMu.RLock()
	defer s.trustSafetyMu.RUnlock()
	if s.trustSafetySticky {
		return true, trustSafetyJournalHealthReason
	}
	if s.trustSafetyReplayBlocked {
		return true, trustSafetyReplayHealthReason
	}
	return false, ""
}

func (s *Server) setPendingHardUntrustEntries(entries []hardUntrustJournalEntry) {
	if s == nil {
		return
	}
	pending := make(map[string]int, len(entries))
	for _, entry := range entries {
		pending[entry.SEKeySHA256]++
	}
	s.trustSafetyMu.Lock()
	s.pendingHardUntrustKeyHashes = pending
	s.trustSafetyMu.Unlock()
}

func (s *Server) trustReuseIdentityPending(seKey string) bool {
	if s == nil || seKey == "" {
		return false
	}
	digest := hashSEPublicKey(seKey)
	s.trustSafetyMu.RLock()
	defer s.trustSafetyMu.RUnlock()
	return s.pendingHardUntrustKeyHashes[digest] > 0
}

// InitializeTrustReuseJournal creates and validates the local durable journal.
// Production calls this through SeedTrustReuseCache before the HTTP listener is
// started.
func (s *Server) InitializeTrustReuseJournal() error {
	if s == nil || s.trustReuseJournal == nil {
		return nil
	}
	if err := s.trustReuseJournal.Initialize(); err != nil {
		s.latchTrustSafety(err)
		return fmt.Errorf("initialize trust-reuse revocation journal: %w", err)
	}
	if fileJournal, ok := s.trustReuseJournal.(*fileHardUntrustJournal); ok {
		s.trustAuthorityMu.Lock()
		if s.trustAuthority == nil {
			authority, lockErr := acquireTrustAuthorityLock(fileJournal.Path())
			if lockErr != nil {
				s.trustAuthorityMu.Unlock()
				s.latchTrustSafety(lockErr)
				return fmt.Errorf("acquire single trust authority: %w", lockErr)
			}
			s.trustAuthority = authority
		}
		s.trustAuthorityMu.Unlock()
	}
	entries, err := s.trustReuseJournal.Load()
	if err != nil {
		s.latchTrustSafety(err)
		return fmt.Errorf("load trust-reuse revocation journal: %w", err)
	}
	s.setPendingHardUntrustEntries(entries)
	return nil
}

// SeedTrustReuseCache wires durable invalidation on hard untrust, wires the store
// into the trust-reuse cache, and seeds the cache from persisted records at
// startup (DAR-326 Phase 0). This is what makes the reuse cache survive a
// coordinator restart / blue-green deploy so a fresh instance does not re-run a
// fleet-wide live MDM SecurityInfo + APNs verification. Safe to call once during
// server setup. The hard-untrust hook is wired UNCONDITIONALLY (independent of
// store presence) so a hard untrust always drops the in-memory record even under
// the memory-store fallback; persistence + startup seeding are skipped when no
// store is wired. SECURITY: seeding TRUSTS the DB contents — a row that says
// `hardware` is loaded as a fast-skip candidate. That trust is bounded because
// reuseTrust re-validates every row on read behind an always-run live SE challenge
// (re-proving SIP/Secure-Boot posture + binary + identity) and rejects future-
// dated rows, so a stale/wrong-binary/expired/forged row still falls through to a
// full live MDM verify — seeding cannot grant hardware by itself. The write path
// (provider_trust_reuse table) must therefore be guarded like the payment ledger
// (Threat-Model #5): only the coordinator writes it, after a verified live MDM
// pass. SEC-004: a forged localhost MDM webhook that drove a grant would be
// persisted + reseeded here (amplified across restarts); bounded by the
// localhost-only webhook, fully mitigated by authenticating it (tracked separately).
func (s *Server) SeedTrustReuseCache(ctx context.Context) error {
	if s == nil || s.trustReuseCache == nil {
		return nil
	}
	s.trustRevocationMu.Lock()
	defer s.trustRevocationMu.Unlock()
	if s.registry != nil {
		s.registry.SetHardUntrustHook(s.invalidateTrustReuse)
	}
	if err := s.InitializeTrustReuseJournal(); err != nil {
		return err
	}
	if s.store == nil {
		if s.trustReuseJournal != nil {
			entries, err := s.trustReuseJournal.Load()
			if err != nil {
				s.latchTrustSafety(err)
				return err
			}
			if len(entries) > 0 {
				s.setTrustReplayBlocked(true)
				return fmt.Errorf("trust-reuse revocation replay requires a durable store")
			}
		}
		return nil
	}
	s.trustReuseCache.store = s.store

	var journalEntries []hardUntrustJournalEntry
	if s.trustReuseJournal != nil {
		var err error
		journalEntries, err = s.trustReuseJournal.Load()
		if err != nil {
			s.latchTrustSafety(err)
			return fmt.Errorf("load trust-reuse revocation journal: %w", err)
		}
		s.setPendingHardUntrustEntries(journalEntries)
	}

	rows, err := s.store.ListProviderTrustReuse(ctx)
	if err != nil {
		if len(journalEntries) > 0 {
			s.setTrustReplayBlocked(true)
			return fmt.Errorf("list trust-reuse rows for revocation replay: %w", err)
		}
		s.logger.Warn("trust-reuse: failed to seed reuse cache from store", "error", err)
		return nil
	}

	excluded := make(map[int]struct{})
	var replayErr error
	for _, entry := range journalEntries {
		matched := false
		replayed := true
		for index, row := range rows {
			if row.SEPubKey == "" || hashSEPublicKey(row.SEPubKey) != entry.SEKeySHA256 {
				continue
			}
			matched = true
			excluded[index] = struct{}{}
			authoritative, err := s.revokePersistedTrustReuseWithRetry(
				s.store, row.SEPubKey, entry.RevocationID)
			if err != nil {
				replayed = false
				if replayErr == nil {
					replayErr = fmt.Errorf("replay hard-untrust revocation: %w", err)
				}
				continue
			}
			s.trustReuseCache.installAuthoritativeTrustReuse(authoritative)
		}
		// A hard untrust during a store outage for an identity with no
		// provider_trust_reuse row leaves an entry that matches nothing above.
		// Entries carrying the plaintext SE key create the missing tombstone
		// (RevokeProviderTrustReuse upserts on absence) and converge; legacy
		// digest-only entries stay pending and keep denying via the pending set.
		if !matched && entry.SEPubKey != "" {
			matched = true
			authoritative, err := s.revokePersistedTrustReuseWithRetry(
				s.store, entry.SEPubKey, entry.RevocationID)
			if err != nil {
				replayed = false
				if replayErr == nil {
					replayErr = fmt.Errorf("replay hard-untrust revocation: %w", err)
				}
			} else {
				s.trustReuseCache.installAuthoritativeTrustReuse(authoritative)
			}
		}
		if !matched || !replayed {
			continue
		}
		remaining, err := s.trustReuseJournal.Remove(entry)
		if err != nil {
			s.latchTrustSafety(err)
			if replayErr == nil {
				replayErr = fmt.Errorf("remove replayed trust-reuse revocation: %w", err)
			}
			continue
		}
		s.setPendingHardUntrustEntries(remaining)
	}

	seedRows := make([]store.ProviderTrustReuse, 0, len(rows))
	for index, row := range rows {
		if _, skip := excluded[index]; skip || s.trustReuseIdentityPending(row.SEPubKey) {
			continue
		}
		seedRows = append(seedRows, row)
	}
	if replayErr != nil {
		s.setTrustReplayBlocked(true)
		return replayErr
	}
	s.setTrustReplayBlocked(false)
	n := s.trustReuseCache.seed(seedRows)
	if n > 0 {
		s.logger.Info("trust-reuse: seeded reuse cache from persisted records (survives deploys)", "records", n)
	}
	return nil
}

// providerApplicationBinaryHash resolves the binary measured for this
// connection. A registration hash is authoritative when present. Hashless
// registrations may use fresh application evidence only while it remains
// installed and bound to both the verified SE identity and this provider
// process's current public key.
func providerApplicationBinaryHash(provider *registry.Provider, seKey, registrationHash string) string {
	if registrationHash != "" {
		return registrationHash
	}
	if provider == nil || seKey == "" {
		return ""
	}

	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	evidence := provider.ApplicationEvidence
	if evidence.EvidenceGeneration == 0 || evidence.SEPublicKey != seKey ||
		provider.PublicKey == "" || evidence.ProcessPublicKey != provider.PublicKey {
		return ""
	}
	return evidence.BinaryHash
}

// recordTrustReuse persists a reviewed, synchronous full MDM/MDA verification.
// It is the only path allowed to clear a durable revocation tombstone, and then
// only at the exact generation observed before the write. A concurrent hard
// untrust increments that generation and wins both the store CAS and the
// provider epoch checks.
func (s *Server) recordTrustReuse(provider *registry.Provider, seKey, serial, binaryHash string, sipEnabled, secureBootFull bool, udid string) bool {
	return s.recordTrustReuseAtGeneration(provider, seKey, serial, binaryHash, sipEnabled, secureBootFull, udid, true)
}

// recordLateTrustReuse records a late MDM/APNs callback without revocation
// recovery authority. A tombstoned row or cache entry remains tombstoned.
func (s *Server) recordLateTrustReuse(provider *registry.Provider, seKey, serial, binaryHash string, sipEnabled, secureBootFull bool, udid string) bool {
	return s.recordTrustReuseAtGeneration(provider, seKey, serial, binaryHash, sipEnabled, secureBootFull, udid, false)
}

func (s *Server) recordTrustReuseAtGeneration(provider *registry.Provider, seKey, serial, binaryHash string, sipEnabled, secureBootFull bool, udid string, allowRecovery bool) bool {
	if s == nil || s.trustReuseCache == nil || provider == nil ||
		seKey == "" || serial == "" {
		return false
	}
	if blocked, _ := s.trustSafetyStatus(); blocked || s.trustReuseIdentityPending(seKey) {
		return false
	}
	if binaryHash == "" {
		// The self-reported binary hash is OPTIONAL (v0.6.0: drift telemetry).
		// A provider omitting it has still fully proven its DEVICE (SE identity
		// + live MDM posture), so hardware trust is granted for this connection.
		// Only the durable reuse record and its cache entry require the hash —
		// a hashless row could never satisfy the read gate, so nothing is
		// persisted or cached (fail-closed: no unbindable reuse rows).
		return s.grantDeviceTrustWithoutReuseRecord(provider, seKey, serial, allowRecovery)
	}
	normHash, err := normalizeSHA256Hex(binaryHash, "binary_hash")
	if err != nil {
		return false
	}
	expectedRevocationGeneration, revocationEventID := s.trustReuseCache.revocationState(seKey)
	now := s.trustReuseCache.now()
	var applicationVerifiedAt *time.Time
	if evidence, ok := provider.ApplicationEvidenceSnapshot(); ok {
		at := evidence.VerifiedAt
		applicationVerifiedAt = &at
	}
	rec := store.ProviderTrustReuse{
		SEPubKey:                   seKey,
		Serial:                     serial,
		TrustLevel:                 string(registry.TrustHardware),
		LastVerifiedBinaryHash:     normHash,
		SIPEnabled:                 sipEnabled,
		SecureBootFull:             secureBootFull,
		MDAUDID:                    udid,
		HardwareProofVerifiedAt:    now,
		ApplicationProofVerifiedAt: applicationVerifiedAt,
		// A full live verification anchors the continuity chain: coverage
		// starts at the verification instant and is advanced only while the
		// coordinator observes this connection live and hardware-trusted.
		ContinuousCoverageUntil: coverageToStore(now),
		RevocationGeneration:    expectedRevocationGeneration,
		RevocationEventID:       revocationEventID,
	}
	epoch := provider.HardUntrustEpoch()
	if provider.ChallengeShouldStop() {
		return false
	}

	st := s.trustReuseCache.store
	if st != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		var writeResult store.ProviderTrustReuseWriteResult
		var persistErr error
		if allowRecovery {
			writeResult, persistErr = st.RecoverProviderTrustReuse(
				ctx, rec, expectedRevocationGeneration)
		} else {
			writeResult, persistErr = st.UpsertProviderTrustReuse(
				ctx, rec, expectedRevocationGeneration)
		}
		cancel()
		if persistErr != nil {
			s.logger.Warn("trust-reuse: failed to persist device evidence", "error", persistErr)
			return false
		}
		if !writeResult.Applied {
			s.trustReuseCache.installRevocationGeneration(
				seKey, writeResult.RevocationGeneration)
			return false
		}
		rec.EvidenceGeneration = writeResult.EvidenceGeneration
		rec.RevocationGeneration = writeResult.RevocationGeneration
	} else {
		rec.EvidenceGeneration = 1
	}

	if allowRecovery {
		s.trustReuseCache.recoverTrust(rec, rec.RevocationGeneration)
	} else {
		s.trustReuseCache.recordTrust(rec)
	}
	granted := provider.GrantHardwareEvidenceAtEpochIfNotUntrusted(
		registry.DeviceEvidence{
			SEPublicKey:          seKey,
			Serial:               serial,
			VerifiedAt:           rec.HardwareProofVerifiedAt,
			EvidenceGeneration:   rec.EvidenceGeneration,
			RevocationGeneration: rec.RevocationGeneration,
		},
		epoch,
	)
	if granted {
		s.markTrustCoverage(seKey, provider.ID)
		return true
	}
	if provider.HardUntrustEpoch() == epoch {
		return false
	}
	revocationEventID = uuid.NewString()
	s.trustReuseCache.invalidateReuse(seKey, revocationEventID)
	if err := s.persistHardUntrustRevocation(seKey, revocationEventID); err != nil {
		s.logger.Warn("trust-reuse: failed to preserve revocation after raced device-evidence write",
			"error", err, "attempts", trustReuseDeleteAttempts)
	}
	return false
}

// grantDeviceTrustWithoutReuseRecord grants hardware trust from a completed
// live device verification for a provider that did not self-report a binary
// hash. No reuse row is persisted or cached — every reconnect re-runs the full
// live verification. Revocation stays authoritative: the late path
// (allowRecovery=false) refuses a tombstoned identity outright (a tombstone
// remains a tombstone), while the synchronous full-verification path retains
// its recovery authority for the live grant but — having no store CAS to run —
// leaves any durable tombstone in place, so reuse and late callbacks for the
// identity remain blocked.
func (s *Server) grantDeviceTrustWithoutReuseRecord(provider *registry.Provider, seKey, serial string, allowRecovery bool) bool {
	if !allowRecovery && s.trustReuseCache.isRevoked(seKey) {
		return false
	}
	epoch := provider.HardUntrustEpoch()
	if provider.ChallengeShouldStop() {
		return false
	}
	revocationGeneration, _ := s.trustReuseCache.revocationState(seKey)
	granted := provider.GrantHardwareEvidenceAtEpochIfNotUntrusted(
		registry.DeviceEvidence{
			SEPublicKey:          seKey,
			Serial:               serial,
			VerifiedAt:           s.trustReuseCache.now(),
			EvidenceGeneration:   1,
			RevocationGeneration: revocationGeneration,
		},
		epoch,
	)
	if granted {
		s.logger.Info("trust-reuse: hardware trust granted without reuse record (no self-reported binary hash)",
			"serial", serial)
	}
	return granted
}

// invalidateTrustReuse drops a device's reuse record in-memory and installs a
// durable tombstone. Wired as the registry's hard-untrust hook, so every
// hard/security deroute (SIP off, Secure Boot off, binary/model-hash change, MDM
// posture mismatch, serial impersonation, bad encrypted chunk, ...) makes "hard
// untrust always takes effect" durable across restarts.
//
// The in-memory invalidation is synchronous and unconditional. Durable
// revocation runs inline with a bounded retry; every attempt carries the one
// event ID generated for this hard-untrust operation. A transient DB blip cannot
// silently leave stale reusable evidence, an ambiguous commit cannot advance the
// generation twice, and a distinct stale-coordinator event cannot collapse into
// an earlier generation.
func (s *Server) invalidateTrustReuse(seKey string) {
	if s == nil || s.trustReuseCache == nil || seKey == "" {
		return
	}
	// Hard untrust ends the continuity chain immediately and without a final
	// coverage write: the durable tombstone wins and coverage never resurrects.
	s.dropTrustCoverage(seKey)
	revocationEventID := uuid.NewString()
	s.trustReuseCache.invalidateReuse(seKey, revocationEventID)
	if err := s.persistHardUntrustRevocation(seKey, revocationEventID); err != nil {
		s.logger.Warn("trust-reuse: failed to revoke persisted reuse record on hard untrust",
			"error", err, "attempts", trustReuseDeleteAttempts)
	}
}

func (s *Server) persistHardUntrustRevocation(seKey, revocationEventID string) error {
	s.trustRevocationMu.Lock()
	defer s.trustRevocationMu.Unlock()
	entry := newHardUntrustJournalEntry(seKey, revocationEventID)
	journaled := false
	var journalErr error
	if s.trustReuseJournal != nil {
		entries, err := s.trustReuseJournal.Append(entry)
		if err != nil {
			journalErr = fmt.Errorf("append hard-untrust revocation journal: %w", err)
			s.latchTrustSafety(journalErr)
		} else {
			journaled = true
			s.setPendingHardUntrustEntries(entries)
		}
	}

	st := s.trustReuseCache.store
	if st == nil {
		if journaled {
			s.setTrustReplayBlocked(true)
		}
		return journalErr
	}
	authoritative, err := s.revokePersistedTrustReuseWithRetry(
		st, seKey, revocationEventID)
	if err != nil {
		s.setTrustReplayBlocked(true)
		if journaled {
			s.scheduleHardUntrustReplay(seKey, entry)
		}
		return fmt.Errorf("revoke persisted trust reuse: %w", err)
	}
	s.trustReuseCache.installAuthoritativeTrustReuse(authoritative)

	if journaled {
		remaining, err := s.trustReuseJournal.Remove(entry)
		if err != nil {
			cleanupErr := fmt.Errorf("remove durable hard-untrust journal entry: %w", err)
			s.latchTrustSafety(cleanupErr)
			return cleanupErr
		}
		s.setPendingHardUntrustEntries(remaining)
		if len(remaining) == 0 {
			s.setTrustReplayBlocked(false)
		}
	}
	return journalErr
}

func (s *Server) scheduleHardUntrustReplay(
	seKey string,
	entry hardUntrustJournalEntry,
) {
	if s == nil || s.trustReplayCtx == nil ||
		s.trustReuseJournal == nil || s.trustReuseCache == nil {
		return
	}
	key := entry.SEKeySHA256 + "\x00" + entry.RevocationID
	s.trustReplayMu.Lock()
	if _, exists := s.trustReplayInFlight[key]; exists {
		s.trustReplayMu.Unlock()
		return
	}
	s.trustReplayInFlight[key] = struct{}{}
	s.trustReplayMu.Unlock()

	saferun.Go(s.logger, "trustReuseRevocationReplay", func() {
		defer func() {
			s.trustReplayMu.Lock()
			delete(s.trustReplayInFlight, key)
			s.trustReplayMu.Unlock()
		}()
		delay := trustReuseReplayInitialBackoff
		for {
			select {
			case <-s.trustReplayCtx.Done():
				return
			case <-time.After(delay):
			}

			s.trustRevocationMu.Lock()
			st := s.trustReuseCache.store
			if st == nil {
				s.trustRevocationMu.Unlock()
				delay = min(delay*2, 30*time.Second)
				continue
			}
			authoritative, err := s.revokePersistedTrustReuseWithRetry(
				st, seKey, entry.RevocationID,
			)
			if err == nil {
				s.trustReuseCache.installAuthoritativeTrustReuse(authoritative)
				remaining, removeErr := s.trustReuseJournal.Remove(entry)
				if removeErr != nil {
					s.latchTrustSafety(removeErr)
					s.trustRevocationMu.Unlock()
					return
				}
				s.setPendingHardUntrustEntries(remaining)
				if len(remaining) == 0 {
					s.setTrustReplayBlocked(false)
				}
				s.trustRevocationMu.Unlock()
				return
			}
			s.trustRevocationMu.Unlock()
			delay = min(delay*2, 30*time.Second)
		}
	})
}

// revokePersistedTrustReuseWithRetry reuses one stable event identity across all
// bounded attempts and returns the store's authoritative row.
func (s *Server) revokePersistedTrustReuseWithRetry(st trustReuseStore, seKey, revocationEventID string) (store.ProviderTrustReuse, error) {
	var (
		authoritative store.ProviderTrustReuse
		err           error
	)
	for attempt := range trustReuseDeleteAttempts {
		if attempt > 0 {
			time.Sleep(trustReuseDeleteRetryBackoff)
		}
		authoritative, err = revokeProviderTrustReuseOnce(
			st, seKey, revocationEventID)
		if err == nil {
			return authoritative, nil
		}
	}
	return authoritative, err
}

func revokeProviderTrustReuseOnce(st trustReuseStore, seKey, revocationEventID string) (store.ProviderTrustReuse, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return st.RevokeProviderTrustReuse(ctx, seKey, revocationEventID)
}

func (s *Server) trustReuseMetric(decision trustReuseDecision, reason trustReuseReason) {
	decisionLabel := string(decision)
	if decisionLabel == "" {
		decisionLabel = "rejected"
	}
	s.ddIncr("trust_reuse.decisions", []string{
		"decision:" + decisionLabel,
		"reason:" + string(reason),
	})
	if s.metrics != nil {
		s.metrics.IncCounter("trust_reuse_decisions_total",
			MetricLabel{"decision", decisionLabel},
			MetricLabel{"reason", string(reason)})
	}
}

// tryTrustReuseFastSkip consumes durable device evidence only after the caller
// has verified a fresh registration-bound signed challenge. A changed binary is
// admitted solely through the optional immutable server-derived release fact.
func (s *Server) tryTrustReuseFastSkip(providerID string, provider *registry.Provider, resp *protocol.AttestationResponseMessage, statusFieldsTrusted bool, facts ...approvedReleaseTransitionFact) bool {
	reject := func(reason trustReuseReason) bool {
		s.trustReuseMetric("", reason)
		return false
	}
	if s == nil || s.trustReuseCache == nil || provider == nil || resp == nil {
		return false
	}
	if blocked, _ := s.trustSafetyStatus(); blocked {
		return reject(trustReuseReasonRevocationSafety)
	}
	if s.mdmClient == nil {
		return reject(trustReuseReasonNoDeviceEvidence)
	}
	if !statusFieldsTrusted ||
		resp.SIPEnabled == nil || !*resp.SIPEnabled ||
		resp.SecureBootEnabled == nil || !*resp.SecureBootEnabled {
		return reject(trustReuseReasonRecordedPostureBad)
	}
	if provider.ChallengeShouldStop() {
		return reject(trustReuseReasonRevoked)
	}
	provider.Mu().Lock()
	var seKey, serial string
	if provider.AttestationResult != nil {
		seKey = provider.AttestationResult.PublicKey
		serial = provider.AttestationResult.SerialNumber
	}
	provider.Mu().Unlock()
	if seKey == "" || serial == "" {
		return reject(trustReuseReasonMissingIdentity)
	}
	if s.trustReuseIdentityPending(seKey) {
		return reject(trustReuseReasonRevocationSafety)
	}
	freshBinaryHash, err := normalizeSHA256Hex(resp.BinaryHash, "binary_hash")
	if err != nil {
		return reject(trustReuseReasonMissingIdentity)
	}
	var fact approvedReleaseTransitionFact
	if len(facts) > 0 {
		fact = facts[0]
	}
	result := s.trustReuseCache.decideTrustReuse(trustReuseInput{
		SEPubKey:          seKey,
		Serial:            serial,
		FreshBinaryHash:   freshBinaryHash,
		ReleaseTransition: fact,
	})
	if result.Decision == "" {
		return reject(result.Reason)
	}
	record := result.Record
	if result.Decision == trustReuseDecisionApprovedReleaseTransition ||
		result.Decision == trustReuseDecisionContinuityReleaseTransition {
		evidence, ok := provider.ApplicationEvidenceSnapshot()
		if !ok || evidence.BinaryHash != freshBinaryHash ||
			evidence.Version != fact.Version ||
			evidence.Platform != fact.Platform ||
			evidence.Backend != fact.Backend {
			return reject(trustReuseReasonTransitionUnapproved)
		}
		// The approved A→B transition has just proven binary B (fresh signed
		// challenge + verified application evidence). Advance the cached and
		// durable application identity to B so a later deactivation of
		// release A (ApprovedFromBinaryHashes only lists ACTIVE predecessors)
		// cannot orphan the record and force this device back to live MDM.
		// The hardware-proof timestamp is deliberately NOT refreshed — it
		// still dates the last live device verification, so the reuse window
		// keeps expiring on the hardware proof, not on binary churn.
		record.lastVerifiedBinaryHash = freshBinaryHash
		at := evidence.VerifiedAt
		record.applicationProofVerifiedAt = &at
	}
	// Every valid reuse grant (window-fresh OR continuity) re-anchors the
	// continuity chain at the grant instant: a continuity fast-skip is itself
	// proof of a normal-OS boot (the live SE challenge just ran), so chained
	// sub-allowance gaps each extend coverage. The hardware-proof timestamp is
	// NEVER advanced by reuse — only a full live MDM verification moves it.
	record.continuousCoverageUntil = s.trustReuseCache.now()
	epoch := provider.HardUntrustEpoch()
	rec := store.ProviderTrustReuse{
		SEPubKey:                   seKey,
		Serial:                     record.serial,
		TrustLevel:                 record.trustLevel,
		LastVerifiedBinaryHash:     record.lastVerifiedBinaryHash,
		SIPEnabled:                 record.sipEnabled,
		SecureBootFull:             record.secureBootFull,
		MDAUDID:                    record.mdaUDID,
		HardwareProofVerifiedAt:    record.hardwareProofVerifiedAt,
		ApplicationProofVerifiedAt: record.applicationProofVerifiedAt,
		ContinuousCoverageUntil:    coverageToStore(record.continuousCoverageUntil),
		EvidenceGeneration:         record.evidenceGeneration,
		RevocationGeneration:       record.revocationGeneration,
		RevocationEventID:          record.revocationEventID,
	}
	if st := s.trustReuseCache.store; st != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		writeResult, persistErr := st.UpsertProviderTrustReuse(
			ctx, rec, record.revocationGeneration)
		cancel()
		if persistErr != nil || !writeResult.Applied {
			if persistErr != nil {
				s.logger.Warn("trust-reuse: durable grant CAS failed", "error", persistErr)
			}
			if !writeResult.Applied {
				s.trustReuseCache.installRevocationGeneration(
					seKey, writeResult.RevocationGeneration)
			}
			return reject(trustReuseReasonRevoked)
		}
		record.evidenceGeneration = writeResult.EvidenceGeneration
		record.revocationGeneration = writeResult.RevocationGeneration
		rec.EvidenceGeneration = writeResult.EvidenceGeneration
		rec.RevocationGeneration = writeResult.RevocationGeneration
	}
	s.trustReuseCache.recordTrust(rec)
	if !provider.GrantHardwareEvidenceAtEpochIfNotUntrusted(registry.DeviceEvidence{
		SEPublicKey:          seKey,
		Serial:               serial,
		VerifiedAt:           record.hardwareProofVerifiedAt,
		EvidenceGeneration:   record.evidenceGeneration,
		RevocationGeneration: record.revocationGeneration,
	}, epoch) {
		return reject(trustReuseReasonRevoked)
	}
	s.markTrustCoverage(seKey, providerID)
	provider.SetMDMFailureReason("")
	s.sendTrustStatus(provider, registry.TrustHardware, "online", string(result.Decision))
	s.registry.PersistProvider(provider)
	s.trustReuseMetric(result.Decision, trustReuseReasonAllowed)
	s.logger.Info("trust-reuse granted hardware without live MDM or APNs",
		"provider_id", providerID,
		"decision", result.Decision,
		"mda_udid", result.Record.mdaUDID,
	)
	return true
}

// --- Connection-continuity coverage tracking ---
//
// The coordinator advances a durable ContinuousCoverageUntil watermark for
// every provider it currently observes connected AND hardware-trusted on a
// live SE-challenged connection anchored at a full live verification or a
// valid reuse grant. Writes are batched (one upsert pass every
// trustCoverageWriteInterval — no per-provider goroutines) plus exact-time
// sweeps on provider disconnect and graceful coordinator shutdown. A
// coordinator crash simply leaves the last periodic write standing, so the
// measured gap is only ever OVER-estimated (fail-safe: continuity refuses,
// full live verification runs).

// trustCoverageWriteInterval is the batched periodic coverage-write cadence.
// Also the crash slack: after a coordinator crash the watermark lags the true
// disconnect by at most one interval, which the 90s reconnect allowance and
// the 120s security ceiling both comfortably absorb without ever admitting a
// RecoveryOS round-trip (>= ~3 minutes).
const trustCoverageWriteInterval = 30 * time.Second

// markTrustCoverage registers seKey as covered by providerID's live
// connection. Called only from grant paths that just proved the connection
// (full live verification or a reuse grant behind a fresh SE challenge).
func (s *Server) markTrustCoverage(seKey, providerID string) {
	if s == nil || seKey == "" || providerID == "" {
		return
	}
	s.trustCoverageMu.Lock()
	if s.trustCoverage == nil {
		s.trustCoverage = make(map[string]string)
	}
	s.trustCoverage[seKey] = providerID
	s.trustCoverageMu.Unlock()
}

// dropTrustCoverage ends coverage for an identity WITHOUT a final write
// (hard untrust: the tombstone wins, coverage never resurrects).
func (s *Server) dropTrustCoverage(seKey string) {
	if s == nil || seKey == "" {
		return
	}
	s.trustCoverageMu.Lock()
	delete(s.trustCoverage, seKey)
	s.trustCoverageMu.Unlock()
}

// trustCoverageValid reports whether the covered connection is still worth a
// coverage write: provider present, not (recoverably or hard) untrusted, still
// hardware-trusted, and still bound to the same SE identity. allowOffline is
// set by the disconnect/shutdown sweeps, where the socket being gone is the
// event being stamped rather than a reason to skip the stamp.
func (s *Server) trustCoverageValid(seKey, providerID string, allowOffline bool) bool {
	if s.registry == nil {
		return false
	}
	p := s.registry.GetProvider(providerID)
	if p == nil {
		return false
	}
	switch p.GetStatus() {
	case registry.StatusUntrusted:
		return false
	case registry.StatusOffline:
		if !allowOffline {
			return false
		}
	}
	if p.GetTrustLevel() != registry.TrustHardware {
		return false
	}
	ar := p.GetAttestationResult()
	return ar != nil && ar.PublicKey == seKey
}

// persistTrustCoverage advances the watermark for the given identities in the
// cache and, when a store is wired, durably in one batched pass. A store blip
// only under-advances the durable watermark (fail-safe).
func (s *Server) persistTrustCoverage(seKeys []string, until time.Time) {
	if len(seKeys) == 0 || s.trustReuseCache == nil {
		return
	}
	s.trustReuseCache.advanceCoverage(seKeys, until)
	st := s.trustReuseCache.store
	if st == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	err := st.AdvanceProviderTrustReuseCoverage(ctx, seKeys, until)
	cancel()
	if err != nil && s.logger != nil {
		s.logger.Warn("trust-reuse: failed to persist continuity coverage",
			"error", err, "providers", len(seKeys))
	}
}

// sweepTrustCoverage performs one batched periodic coverage pass: every entry
// still observed live and hardware-trusted is advanced to now; entries that
// lost trust or vanished without hitting the disconnect hook are dropped
// without a write (their watermark stays at the previous pass — gap
// over-estimated, fail-safe). Returns the number of identities advanced.
func (s *Server) sweepTrustCoverage() int {
	if s == nil || s.trustReuseCache == nil {
		return 0
	}
	now := s.trustReuseCache.now()
	var covered []string
	s.trustCoverageMu.Lock()
	for seKey, providerID := range s.trustCoverage {
		if s.trustCoverageValid(seKey, providerID, false) {
			covered = append(covered, seKey)
		} else {
			delete(s.trustCoverage, seKey)
		}
	}
	s.trustCoverageMu.Unlock()
	s.persistTrustCoverage(covered, now)
	return len(covered)
}

// stopTrustCoverageForProvider ends coverage for a disconnecting connection,
// stamping the EXACT coordinator-observed disconnect time so the measured
// reconnect gap starts at zero rather than at the last periodic pass.
func (s *Server) stopTrustCoverageForProvider(providerID string) {
	if s == nil || providerID == "" || s.trustReuseCache == nil {
		return
	}
	now := s.trustReuseCache.now()
	var ended []string
	s.trustCoverageMu.Lock()
	for seKey, id := range s.trustCoverage {
		if id != providerID {
			continue
		}
		if s.trustCoverageValid(seKey, providerID, true) {
			ended = append(ended, seKey)
		}
		delete(s.trustCoverage, seKey)
	}
	s.trustCoverageMu.Unlock()
	s.persistTrustCoverage(ended, now)
}

// finalTrustCoverageSweep is the graceful coordinator-shutdown sweep: it
// persists the exact shutdown instant for every still-covered provider so a
// short deploy (gap under the reconnect allowance) reconnects into a
// continuity fast-skip on the next coordinator instead of a fleet-wide live
// MDM herd. Clears the tracker; only Server.Close calls this.
func (s *Server) finalTrustCoverageSweep() {
	if s == nil || s.trustReuseCache == nil {
		return
	}
	now := s.trustReuseCache.now()
	var ended []string
	s.trustCoverageMu.Lock()
	for seKey, providerID := range s.trustCoverage {
		if s.trustCoverageValid(seKey, providerID, true) {
			ended = append(ended, seKey)
		}
		delete(s.trustCoverage, seKey)
	}
	s.trustCoverageMu.Unlock()
	s.persistTrustCoverage(ended, now)
}

// trustCoverageLoop drives the batched periodic coverage writes until the
// server closes. One goroutine for the whole fleet.
func (s *Server) trustCoverageLoop() {
	ticker := time.NewTicker(trustCoverageWriteInterval)
	defer ticker.Stop()
	for {
		select {
		case <-s.trustCoverageCtx.Done():
			return
		case <-ticker.C:
			s.sweepTrustCoverage()
		}
	}
}
