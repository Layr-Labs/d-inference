package api

import (
	"context"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

const (
	defaultHardwareProofTTL = time.Hour
	minHardwareProofTTL     = time.Hour
	maxHardwareProofTTL     = 24 * time.Hour
)

const (
	trustReuseGrantWait = 10 * time.Second
	trustReuseGrantPoll = 100 * time.Millisecond
)

const clockSkewTolerance = 2 * time.Minute
const trustReuseDeleteAttempts = 3

var trustReuseDeleteRetryBackoff = 200 * time.Millisecond

type trustReuseDecision string

const (
	trustReuseDecisionSameBinary                trustReuseDecision = "same_binary"
	trustReuseDecisionApprovedReleaseTransition trustReuseDecision = "approved_release_transition"
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
	RevokeProviderTrustReuse(ctx context.Context, seKey, revocationEventID string) (store.ProviderTrustReuse, error)
}

type trustReuseCache struct {
	mu      sync.Mutex
	records map[string]trustReuseRecord

	reuseWindow time.Duration
	now         func() time.Time
	store       trustReuseStore
}

type trustReuseRecord struct {
	serial                     string
	trustLevel                 string
	lastVerifiedBinaryHash     string
	sipEnabled                 bool
	secureBootFull             bool
	mdaUDID                    string
	hardwareProofVerifiedAt    time.Time
	applicationProofVerifiedAt *time.Time
	evidenceGeneration         uint64
	revocationGeneration       uint64
	revocationEventID          string
	revokedAt                  *time.Time
}

func clampHardwareProofTTL(d time.Duration) time.Duration {
	if d == 0 {
		return defaultHardwareProofTTL
	}
	if d < minHardwareProofTTL {
		return minHardwareProofTTL
	}
	if d > maxHardwareProofTTL {
		return maxHardwareProofTTL
	}
	return d
}

func newTrustReuseCache() *trustReuseCache {
	return newTrustReuseCacheWithTTL(defaultHardwareProofTTL)
}

func newTrustReuseCacheWithTTL(ttl time.Duration) *trustReuseCache {
	return &trustReuseCache{
		records:     make(map[string]trustReuseRecord),
		reuseWindow: clampHardwareProofTTL(ttl),
		now:         time.Now,
	}
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
	if age := c.now().Sub(r.hardwareProofVerifiedAt); age < -clockSkewTolerance || age >= c.reuseWindow {
		return trustReuseResult{Reason: trustReuseReasonProofExpired}
	}
	if r.lastVerifiedBinaryHash == input.FreshBinaryHash {
		return trustReuseResult{
			Decision: trustReuseDecisionSameBinary,
			Reason:   trustReuseReasonAllowed,
			Record:   r,
		}
	}
	if _, approvedFrom := input.ReleaseTransition.ApprovedFromBinaryHashes[r.lastVerifiedBinaryHash]; input.ReleaseTransition.Approved && approvedFrom &&
		input.ReleaseTransition.BinaryHash == input.FreshBinaryHash {
		return trustReuseResult{
			Decision: trustReuseDecisionApprovedReleaseTransition,
			Reason:   trustReuseReasonAllowed,
			Record:   r,
		}
	}
	return trustReuseResult{Reason: trustReuseReasonTransitionUnapproved}
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
	age := c.now().Sub(r.hardwareProofVerifiedAt)
	return age >= -clockSkewTolerance && age < c.reuseWindow
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
		evidenceGeneration:         rec.EvidenceGeneration,
		revocationGeneration:       rec.RevocationGeneration,
		revocationEventID:          rec.RevocationEventID,
		revokedAt:                  rec.RevokedAt,
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

func (c *trustReuseCache) seed(rows []store.ProviderTrustReuse) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
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
		if incoming.revokedAt == nil {
			age := now.Sub(incoming.hardwareProofVerifiedAt)
			if age < -clockSkewTolerance || age >= c.reuseWindow {
				continue
			}
		}
		c.records[row.SEPubKey] = incoming
		if incoming.revokedAt == nil {
			n++
		}
	}
	return n
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
func (s *Server) SeedTrustReuseCache(ctx context.Context) {
	if s == nil || s.trustReuseCache == nil {
		return
	}
	// Wire durable invalidation UNCONDITIONALLY — independent of store presence. A
	// HARD untrust must always drop the in-memory record (and, when a store is
	// wired, the persisted row too), so a hard-untrusted device cannot fast-skip on
	// reconnect even under the memory-store fallback (FIX 5).
	if s.registry != nil {
		s.registry.SetHardUntrustHook(s.invalidateTrustReuse)
	}
	// Persistence + startup seeding require a store; the in-memory reuse cache works
	// identically with or without one.
	if s.store == nil {
		return
	}
	// Wire the write-through path so future successful verifications are persisted.
	s.trustReuseCache.store = s.store

	rows, err := s.store.ListProviderTrustReuse(ctx)
	if err != nil {
		s.logger.Warn("trust-reuse: failed to seed reuse cache from store", "error", err)
		return
	}
	n := s.trustReuseCache.seed(rows)
	if n > 0 {
		s.logger.Info("trust-reuse: seeded reuse cache from persisted records (survives deploys)", "records", n)
	}
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
		seKey == "" || serial == "" || binaryHash == "" {
		return false
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
		RevocationGeneration:       expectedRevocationGeneration,
		RevocationEventID:          revocationEventID,
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
		return true
	}
	if provider.HardUntrustEpoch() == epoch {
		return false
	}
	revocationEventID = uuid.NewString()
	s.trustReuseCache.invalidateReuse(seKey, revocationEventID)
	if st != nil {
		authoritative, revokeErr := s.revokePersistedTrustReuseWithRetry(
			st, seKey, revocationEventID)
		if revokeErr != nil {
			s.logger.Warn("trust-reuse: failed to preserve revocation after raced device-evidence write",
				"error", revokeErr, "attempts", trustReuseDeleteAttempts)
		} else {
			s.trustReuseCache.installAuthoritativeTrustReuse(authoritative)
		}
	}
	return false
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
	revocationEventID := uuid.NewString()
	s.trustReuseCache.invalidateReuse(seKey, revocationEventID)
	st := s.trustReuseCache.store
	if st == nil {
		return
	}
	authoritative, err := s.revokePersistedTrustReuseWithRetry(
		st, seKey, revocationEventID)
	if err != nil {
		s.logger.Warn("trust-reuse: failed to revoke persisted reuse record on hard untrust after retries",
			"error", err, "attempts", trustReuseDeleteAttempts)
		return
	}
	s.trustReuseCache.installAuthoritativeTrustReuse(authoritative)
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
	if result.Decision == trustReuseDecisionApprovedReleaseTransition {
		evidence, ok := provider.ApplicationEvidenceSnapshot()
		if !ok || evidence.BinaryHash != freshBinaryHash ||
			evidence.Version != fact.Version ||
			evidence.Platform != fact.Platform ||
			evidence.Backend != fact.Backend {
			return reject(trustReuseReasonTransitionUnapproved)
		}
	}
	record := result.Record
	epoch := provider.HardUntrustEpoch()
	if st := s.trustReuseCache.store; st != nil {
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
			EvidenceGeneration:         record.evidenceGeneration,
			RevocationGeneration:       record.revocationGeneration,
			RevocationEventID:          record.revocationEventID,
		}
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
		s.trustReuseCache.recordTrust(rec)
	}
	if !provider.GrantHardwareEvidenceAtEpochIfNotUntrusted(registry.DeviceEvidence{
		SEPublicKey:          seKey,
		Serial:               serial,
		VerifiedAt:           record.hardwareProofVerifiedAt,
		EvidenceGeneration:   record.evidenceGeneration,
		RevocationGeneration: record.revocationGeneration,
	}, epoch) {
		return reject(trustReuseReasonRevoked)
	}
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

// awaitTrustReuseGrant lets the mdmVerificationLoop briefly defer to the live SE
// challenge's trust-reuse fast-skip before running the (herd-causing) live MDM
// round-trip. It returns true if hardware is granted within trustReuseGrantWait
// (by the fast-skip), false otherwise (challenge settled without
// a grant / hard untrust / ctx done / timeout) — in which case the caller proceeds
// to the full live MDM verify, unchanged. Only invoked for fast-skip candidates
// (hasFreshRecord), so a first-ever / expired device is never delayed.
//
// DAR-326 FIX 3: the challenge-settled signal lets a candidate whose gates DON'T
// pass proceed to the full live verify immediately instead of stalling the whole
// trustReuseGrantWait — the timer is only the backstop for a slow/never-arriving
// challenge.
func (s *Server) awaitTrustReuseGrant(ctx context.Context, provider *registry.Provider) bool {
	settled := provider.ChallengeSettledChan()
	timer := time.NewTimer(trustReuseGrantWait)
	defer timer.Stop()
	ticker := time.NewTicker(trustReuseGrantPoll)
	defer ticker.Stop()
	for {
		if provider.GetTrustLevel() == registry.TrustHardware {
			return true
		}
		if provider.ChallengeShouldStop() {
			return false
		}
		select {
		case <-ctx.Done():
			return false
		case <-settled:
			// The live challenge settled WITHOUT a fast-skip grant — stop waiting and
			// fall through to the full live MDM verify now (no up-to-10s stall). Re-read
			return provider.GetTrustLevel() == registry.TrustHardware
		case <-timer.C:
			return provider.GetTrustLevel() == registry.TrustHardware
		case <-ticker.C:
		}
	}
}
