package api

import (
	"context"
	"os"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// defaultTrustReuseWindow is how long a successful FULL live MDM verification is
// honored for a NEW connection from the same device — without re-running the live
// MDM SecurityInfo round-trip — provided a fresh live SE challenge re-proves the
// SAME identity, binary, and good posture. It bounds the staleness of the MDM
// proof, so it is kept short (mirrors the code-identity reuse window). Overridable
// via EIGENINFERENCE_TRUST_REUSE_WINDOW.
const defaultTrustReuseWindow = 30 * time.Minute

// trustReuseGrantWait bounds how long the per-connection mdmVerificationLoop
// defers to the live SE challenge's trust-reuse fast-skip for a known, recently
// fully-verified device before falling back to the full live MDM round-trip. The
// SE challenge round-trip is sub-second, so this is rarely fully consumed; it
// exists only so this loop does not race AHEAD of the challenge and re-run the
// live MDM verify the fast-skip is meant to avoid — the fleet-wide MDM/APNs herd
// on a planned coordinator restart/swap that this feature targets.
const (
	trustReuseGrantWait = 10 * time.Second
	trustReuseGrantPoll = 100 * time.Millisecond
)

// trustReuseStore is the minimal slice of store.Store the trust-reuse cache needs
// to survive coordinator restarts/blue-green deploys (DAR-326 Phase 0). store.Store
// satisfies it; tests can inject a fake. SECURITY: persistence is a performance
// optimization (avoid a fleet-wide live MDM re-verification within the reuse
// window) — it is NEVER consulted to grant hardware trust. The reuse decision
// (reuseTrust) re-applies, behind a live SE challenge, the identity + binary +
// fresh-posture + freshness gates on every read, so a stale/wrong-binary/expired
// persisted row falls through to a real, full live MDM verification.
type trustReuseStore interface {
	ListProviderTrustReuse(ctx context.Context) ([]store.ProviderTrustReuse, error)
	UpsertProviderTrustReuse(ctx context.Context, rec store.ProviderTrustReuse) error
	DeleteProviderTrustReuse(ctx context.Context, seKey string) error
}

// trustReuseCache lets a planned coordinator restart/swap skip a fleet-wide live
// MDM SecurityInfo + APNs re-verification herd. It mirrors the code-identity reuse
// cache (codeAttestThrottle): one durable record per device of its most recent
// FULL live MDM verification, keyed by the Secure Enclave public key — the stable
// per-device identity that survives reconnects AND coordinator restarts.
//
// On reconnect today, every provider's per-connection mdmVerificationLoop fires a
// live MDM SecurityInfo round-trip (and APNs push) almost immediately; doing that
// across the whole fleet at once (a restart/blue-green swap) is the herd. With a
// fresh record, once the live SE challenge re-proves identity + posture, the
// coordinator grants hardware from the record and the MDM loop skips its live
// round-trip.
//
// SECURITY — the skip is a gated optimization, never a trust shortcut:
//   - The live SE challenge ALWAYS runs first (never skipped). The fast-skip only
//     happens AFTER it passes (verifyChallengeResponse -> tryTrustReuseFastSkip).
//   - reuseTrust re-checks, on every read: SE-key + serial identity match (a), the
//     binary hash in the FRESH signed challenge == the one proven at the last MDM
//     verification (b), the recorded posture was good + trust was hardware, and the
//     freshness window (d). The caller additionally requires fresh good posture
//     cryptographically bound to the SE key (c) and that the provider is not
//     hard-untrusted (e). Any miss falls through to the full live MDM verify —
//     byte-identical to today.
//   - A hard untrust deletes the record (in-memory + persisted), so it can never
//     reseed and fast-skip after a restart. First-ever verification (no record)
//     always does the full live MDM.
type trustReuseCache struct {
	mu      sync.Mutex
	records map[string]trustReuseRecord // seKey -> last successful FULL live MDM verification

	reuseWindow time.Duration

	now func() time.Time

	// store persists the reuse cache across restarts/deploys. nil until wired by
	// Server.SeedTrustReuseCache at startup (and nil in unit tests that construct a
	// bare cache), so every persistence path is nil-safe — the in-memory reuse
	// cache works identically with or without a store.
	store trustReuseStore
}

// trustReuseRecord is the in-memory form of store.ProviderTrustReuse: what was
// proven about a device at its last FULL live MDM verification.
type trustReuseRecord struct {
	serial         string
	trustLevel     string
	binaryHash     string // normalized SHA-256 hex of the provider binary at last verification
	sipEnabled     bool
	secureBootFull bool
	mdaUDID        string
	at             time.Time
}

func newTrustReuseCache() *trustReuseCache {
	return &trustReuseCache{
		records:     make(map[string]trustReuseRecord),
		reuseWindow: trustReuseWindowFromEnv(),
		now:         time.Now,
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

// reuseTrust reports whether the device has a record-side basis to skip a live MDM
// re-verification: a fresh record (within the window) for the SAME SE key + serial,
// earned at HARDWARE trust with good recorded posture, whose recorded binary hash
// matches the one in the fresh SIGNED challenge (freshBinaryHash, already
// normalized by the caller). It does NOT check the fresh posture or hard-untrust
// state — those are the caller's gates (c)/(e) — keeping this method a pure,
// clock-driven record lookup that mirrors codeAttestThrottle.reuseAttestation.
// SECURITY: every field here re-validates the persisted/seeded record on read, so a
// seeded row can never by itself grant trust.
func (c *trustReuseCache) reuseTrust(seKey, serial, freshBinaryHash string) (trustReuseRecord, bool) {
	if seKey == "" || serial == "" || freshBinaryHash == "" {
		return trustReuseRecord{}, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	r, ok := c.records[seKey]
	if !ok {
		return trustReuseRecord{}, false
	}
	if r.serial != serial { // (a) identity: serial bound to the same SE key
		return trustReuseRecord{}, false
	}
	if r.trustLevel != string(registry.TrustHardware) { // only a full MDM/hardware verification is reusable
		return trustReuseRecord{}, false
	}
	if r.binaryHash == "" || r.binaryHash != freshBinaryHash { // (b) code identity unchanged
		return trustReuseRecord{}, false
	}
	if !r.sipEnabled || !r.secureBootFull { // recorded posture must have been good (defensive)
		return trustReuseRecord{}, false
	}
	if c.now().Sub(r.at) >= c.reuseWindow { // (d) freshness window
		return trustReuseRecord{}, false
	}
	return r, true
}

// hasFreshRecord reports whether a fresh, hardware, identity-matching record
// exists for a device. It is a SUBSET of reuseTrust (no binary/posture check) used
// ONLY to decide whether the mdmVerificationLoop should briefly defer to the SE
// challenge's fast-skip. It is a timing hint, never a trust decision — the actual
// grant always goes through reuseTrust + the caller's full gates.
func (c *trustReuseCache) hasFreshRecord(seKey, serial string) bool {
	if seKey == "" || serial == "" {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	r, ok := c.records[seKey]
	if !ok || r.serial != serial || r.trustLevel != string(registry.TrustHardware) {
		return false
	}
	return c.now().Sub(r.at) < c.reuseWindow
}

// recordTrust updates the in-memory reuse record for a device after a successful
// FULL live MDM verification. Mirrors codeAttestThrottle.recordAttested; the
// durable write-through is Server.persistTrustReuse, called alongside it.
func (c *trustReuseCache) recordTrust(rec store.ProviderTrustReuse) {
	if rec.SEPubKey == "" {
		return
	}
	c.mu.Lock()
	c.records[rec.SEPubKey] = trustReuseRecord{
		serial:         rec.Serial,
		trustLevel:     rec.TrustLevel,
		binaryHash:     rec.BinaryHash,
		sipEnabled:     rec.SIPEnabled,
		secureBootFull: rec.SecureBootFull,
		mdaUDID:        rec.MDAUDID,
		at:             rec.VerifiedAt,
	}
	c.mu.Unlock()
}

// invalidateReuse drops any cached reuse record for a device so the NEXT reconnect
// cannot be short-circuited by reuseTrust and must run a full live MDM
// verification. Used on HARD untrust (posture/binary/identity mismatch). This
// drops only the IN-MEMORY record; the caller (Server.invalidateTrustReuse) also
// deletes the PERSISTED row so a coordinator restart cannot reseed and fast-skip
// on a stale, pre-untrust record. Mirrors codeAttestThrottle.invalidateReuse.
func (c *trustReuseCache) invalidateReuse(seKey string) {
	if seKey == "" {
		return
	}
	c.mu.Lock()
	delete(c.records, seKey)
	c.mu.Unlock()
}

// seed loads persisted trust-reuse records into the in-memory cache at startup.
// It applies the SAME freshness window used on read, so only rows that could still
// be reused are kept, and never overwrites a fresher in-memory record (a device
// that reconnected and re-verified before seeding finished). Returns the number of
// rows seeded. Mirrors codeAttestThrottle.seed. SECURITY: seeding only populates
// the cache that reuseTrust re-validates (identity + binary + posture + freshness)
// behind a live SE challenge on every read — it cannot by itself grant hardware.
func (c *trustReuseCache) seed(rows []store.ProviderTrustReuse) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	n := 0
	for _, r := range rows {
		if r.SEPubKey == "" {
			continue
		}
		if now.Sub(r.VerifiedAt) >= c.reuseWindow {
			continue // already outside the reuse window — would never be reused
		}
		if cur, ok := c.records[r.SEPubKey]; ok && !r.VerifiedAt.After(cur.at) {
			continue // keep the fresher in-memory record
		}
		c.records[r.SEPubKey] = trustReuseRecord{
			serial:         r.Serial,
			trustLevel:     r.TrustLevel,
			binaryHash:     r.BinaryHash,
			sipEnabled:     r.SIPEnabled,
			secureBootFull: r.SecureBootFull,
			mdaUDID:        r.MDAUDID,
			at:             r.VerifiedAt,
		}
		n++
	}
	return n
}

// SeedTrustReuseCache wires the store into the trust-reuse cache, wires durable
// invalidation on hard untrust, and seeds the cache from persisted records at
// startup (DAR-326 Phase 0). This is what makes the reuse cache survive a
// coordinator restart / blue-green deploy so a fresh instance does not re-run a
// fleet-wide live MDM SecurityInfo + APNs verification. Safe to call once during
// server setup, AFTER the store is set; a nil store or nil cache is a no-op.
// SECURITY: seeding only repopulates the cache that reuseTrust re-validates (behind
// a live SE challenge) on every read — it cannot grant hardware by itself, and a
// stale/wrong-binary/expired row still falls through to a full live MDM verify.
func (s *Server) SeedTrustReuseCache(ctx context.Context) {
	if s == nil || s.trustReuseCache == nil || s.store == nil {
		return
	}
	// Wire the write-through path so future successful verifications are persisted.
	s.trustReuseCache.store = s.store
	// Wire durable invalidation: a HARD untrust must delete the persisted record so
	// a coordinator restart cannot reseed and fast-skip on a stale, pre-untrust row.
	if s.registry != nil {
		s.registry.SetHardUntrustHook(s.invalidateTrustReuse)
	}

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

// recordTrustReuse writes a successful FULL live MDM verification to the reuse
// cache: in-memory (recordTrust) AND durable write-through (persistTrustReuse), so
// a planned coordinator restart/swap can fast-skip the live MDM round-trip for
// this device within the freshness window. Called from verifyProviderViaMDM AFTER
// hardware is granted. The recorded binary hash is the SE-attested provider binary
// (normalized); the read gate compares it to the binary hash in the fresh SIGNED
// challenge, so a binary change between connections forces a full re-verify. If the
// SE attestation carries no usable binary hash, no record is cached (the read gate
// requires a binary match anyway) — the device simply re-verifies via full MDM next
// time. SECURITY: written only after a full, verified live MDM pass — never from an
// unverified self-report.
func (s *Server) recordTrustReuse(seKey, serial, binaryHash string, sipEnabled, secureBootFull bool, udid string) {
	if s == nil || s.trustReuseCache == nil || seKey == "" || serial == "" {
		return
	}
	normHash, err := normalizeSHA256Hex(binaryHash, "binary_hash")
	if err != nil {
		// No usable signed binary hash to bind the reuse record to; the read gate
		// (b) requires a binary-hash match, so an unbindable record would never be
		// reused. Skip caching rather than store a dead row.
		return
	}
	rec := store.ProviderTrustReuse{
		SEPubKey:       seKey,
		Serial:         serial,
		TrustLevel:     string(registry.TrustHardware),
		BinaryHash:     normHash,
		SIPEnabled:     sipEnabled,
		SecureBootFull: secureBootFull,
		MDAUDID:        udid,
		VerifiedAt:     s.trustReuseCache.now(),
	}
	s.trustReuseCache.recordTrust(rec) // in-memory
	s.persistTrustReuse(rec)           // durable write-through
}

// persistTrustReuse best-effort writes a reuse record to the store off the read
// loop (saferun.Go) so it survives a coordinator restart/deploy. Behind the store
// seam (no-op until SeedTrustReuseCache wires a store). Mirrors
// Server.persistCodeAttestation.
func (s *Server) persistTrustReuse(rec store.ProviderTrustReuse) {
	if s == nil || s.trustReuseCache == nil || rec.SEPubKey == "" {
		return
	}
	st := s.trustReuseCache.store
	if st == nil {
		return
	}
	saferun.Go(s.logger, "persistTrustReuse", func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := st.UpsertProviderTrustReuse(ctx, rec); err != nil {
			s.logger.Warn("trust-reuse: failed to persist reuse record", "error", err)
		}
	})
}

// invalidateTrustReuse drops a device's reuse record in-memory AND deletes the
// persisted row (off the read loop). Wired as the registry's hard-untrust hook, so
// EVERY hard/security deroute (SIP off, Secure Boot off, binary/model-hash change,
// MDM posture mismatch, serial impersonation, bad encrypted chunk, ...) makes
// "hard untrust always takes effect" durable across restarts: the device cannot
// fast-skip on a stale, pre-untrust record after a coordinator restart. No-op when
// no store is wired (in-memory invalidation still applies). Mirrors
// Server.invalidatePersistedCodeAttestation.
func (s *Server) invalidateTrustReuse(seKey string) {
	if s == nil || s.trustReuseCache == nil || seKey == "" {
		return
	}
	s.trustReuseCache.invalidateReuse(seKey)
	st := s.trustReuseCache.store
	if st == nil {
		return
	}
	saferun.Go(s.logger, "invalidateTrustReuse", func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := st.DeleteProviderTrustReuse(ctx, seKey); err != nil {
			s.logger.Warn("trust-reuse: failed to delete persisted reuse record on hard untrust", "error", err)
		}
	})
}

// tryTrustReuseFastSkip is the read-path gate + grant. It runs AFTER the live SE
// challenge has passed (from verifyChallengeResponse). If a fresh trust-reuse
// record re-proves this exact, recently-fully-verified device — and the fresh
// SIGNED challenge re-proves good posture and an unchanged binary — it grants
// hardware immediately and returns true, letting the mdmVerificationLoop skip its
// live MDM SecurityInfo round-trip. Any gate miss returns false (fall through to
// the unchanged full live MDM verify).
//
// Gates (ALL required), mapping to the DAR-326 spec:
//
//	(a) SE pubkey AND serial match the registration-bound attestation;
//	(b) the binary hash in the fresh SIGNED challenge == the cached one;
//	(c) fresh posture is good AND cryptographically bound: SIPEnabled &&
//	    SecureBootEnabled && statusFieldsTrusted;
//	(d) within the freshness window (enforced in reuseTrust);
//	(e) the provider is not currently HARD-untrusted.
func (s *Server) tryTrustReuseFastSkip(providerID string, provider *registry.Provider, resp *protocol.AttestationResponseMessage, statusFieldsTrusted bool) bool {
	if s == nil || s.trustReuseCache == nil || provider == nil || resp == nil {
		return false
	}
	// (c) fresh good posture, cryptographically bound to the SE key. Without a
	// status signature (statusFieldsTrusted == false) the SIP/SecureBoot/binary
	// fields are advisory and must never drive a trust decision.
	if !statusFieldsTrusted {
		return false
	}
	if resp.SIPEnabled == nil || !*resp.SIPEnabled {
		return false
	}
	if resp.SecureBootEnabled == nil || !*resp.SecureBootEnabled {
		return false
	}
	// (e) never fast-skip a hard-untrusted provider. (GrantHardwareIfNotUntrusted
	// below is the authoritative atomic backstop; this is an early-out.)
	if provider.ChallengeShouldStop() {
		return false
	}
	// (a) identity: SE pubkey + serial from the registration-bound attestation —
	// never values supplied in the response.
	provider.Mu().Lock()
	var seKey, serial string
	if provider.AttestationResult != nil {
		seKey = provider.AttestationResult.PublicKey
		serial = provider.AttestationResult.SerialNumber
	}
	provider.Mu().Unlock()
	if seKey == "" || serial == "" {
		return false
	}
	// (b) code identity: the binary hash in the fresh SIGNED challenge must match
	// the one proven at the last full MDM verification (both normalized).
	freshBinaryHash, err := normalizeSHA256Hex(resp.BinaryHash, "binary_hash")
	if err != nil {
		return false
	}
	// reuseTrust enforces (a) serial, (b) binary, (d) freshness + hardware/recorded
	// posture. Any miss → fall through to the full live MDM verify.
	rec, ok := s.trustReuseCache.reuseTrust(seKey, serial, freshBinaryHash)
	if !ok {
		return false
	}
	// Atomically grant hardware unless a concurrent hard untrust raced in (closes
	// the TOCTOU; mirrors verifyProviderViaMDM's grant).
	if !provider.GrantHardwareIfNotUntrusted() {
		return false
	}
	provider.SetMDMFailureReason("")
	s.sendTrustStatus(provider, registry.TrustHardware, "online", "trust-reuse fast-skip (recent MDM verification re-proven by live SE challenge)")
	s.registry.PersistProvider(provider)
	s.ddIncr("mdm.verification", []string{"outcome:granted-trust-reuse"})
	s.logger.Info("trust-reuse fast-skip — granted hardware without live MDM round-trip",
		"provider_id", providerID,
		"serial_number", serial,
		"mda_udid", rec.mdaUDID,
	)
	return true
}

// awaitTrustReuseGrant lets the mdmVerificationLoop briefly defer to the live SE
// challenge's trust-reuse fast-skip before running the (herd-causing) live MDM
// round-trip. It returns true if hardware is granted within trustReuseGrantWait
// (by the fast-skip, or the ACME leg), false otherwise (slow challenge / gate miss
// / hard untrust / ctx done) — in which case the caller proceeds to the full live
// MDM verify, unchanged. Only invoked for fast-skip candidates (hasFreshRecord),
// so a first-ever / expired device is never delayed.
func (s *Server) awaitTrustReuseGrant(ctx context.Context, provider *registry.Provider) bool {
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
		case <-timer.C:
			return provider.GetTrustLevel() == registry.TrustHardware
		case <-ticker.C:
		}
	}
}
