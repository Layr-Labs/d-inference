package authority

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/releases"
	trustreuse "github.com/eigeninference/d-inference/coordinator/internal/provider/reuse"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// recordTrustReuse persists a reviewed, synchronous full MDM/MDA verification.
// It is the only path allowed to clear a durable revocation tombstone, and then
// only at the exact generation observed before the write. A concurrent hard
// untrust increments that generation and wins both the store CAS and the
// provider epoch checks.
func (s *Service,

) RecordTrustReuse(provider *registry.Provider, seKey, serial, binaryHash string, sipEnabled, secureBootFull bool, udid string) bool {
	return s.recordTrustReuseAtGeneration(provider, seKey, serial, binaryHash, sipEnabled, secureBootFull, udid, true)
}

// recordLateTrustReuse records a late MDM/APNs callback without revocation
// recovery authority. A tombstoned row or cache entry remains tombstoned.
func (s *Service,

) RecordLateTrustReuse(provider *registry.Provider, seKey, serial, binaryHash string, sipEnabled, secureBootFull bool, udid string) bool {
	return s.recordTrustReuseAtGeneration(provider, seKey, serial, binaryHash, sipEnabled, secureBootFull, udid, false)
}

func (s *Service,

) recordTrustReuseAtGeneration(provider *registry.Provider, seKey, serial, binaryHash string, sipEnabled, secureBootFull bool, udid string, allowRecovery bool) bool {
	if s == nil || s.trustReuseCache == nil || provider == nil ||
		seKey == "" || serial == "" {
		return false
	}
	if s.legacyMDMAllowed != nil && !s.legacyMDMAllowed(provider) {
		return false
	}
	if blocked, _ := s.TrustSafetyStatus(); blocked || s.DeniesIdentity(seKey) {
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
	normHash, err := releases.NormalizeSHA256Hex(binaryHash, "binary_hash")
	if err != nil {
		return false
	}
	expectedRevocationGeneration, revocationEventID := s.trustReuseCache.RevocationState(seKey)
	now := s.trustReuseCache.Now()
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
		ContinuousCoverageUntil: trustreuse.CoverageToStore(now),
		RevocationGeneration:    expectedRevocationGeneration,
		RevocationEventID:       revocationEventID,
	}
	epoch := provider.HardUntrustEpoch()
	if provider.ChallengeShouldStop() {
		return false
	}

	st := s.trustReuseCache.Store
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
			s.trustReuseCache.InstallRevocationGeneration(
				seKey, writeResult.RevocationGeneration)
			return false
		}
		rec.EvidenceGeneration = writeResult.EvidenceGeneration
		rec.RevocationGeneration = writeResult.RevocationGeneration
	} else {
		rec.EvidenceGeneration = 1
	}

	if allowRecovery {
		s.trustReuseCache.RecoverTrust(rec, rec.RevocationGeneration)
	} else {
		s.trustReuseCache.RecordTrust(rec)
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
		s.MarkTrustCoverage(seKey, provider.ID)
		return true
	}
	if provider.HardUntrustEpoch() == epoch {
		return false
	}
	revocationEventID = uuid.NewString()
	s.trustReuseCache.InvalidateReuse(seKey, revocationEventID)
	if err := s.persistHardUntrustRevocation(seKey, revocationEventID); err != nil {
		s.logger.Warn("trust-reuse: failed to preserve revocation after raced device-evidence write",
			"error", err, "attempts", trustreuse.TrustReuseDeleteAttempts)
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
func (s *Service,

) grantDeviceTrustWithoutReuseRecord(provider *registry.Provider, seKey, serial string, allowRecovery bool) bool {
	if !allowRecovery && s.trustReuseCache.IsRevoked(seKey) {
		return false
	}
	epoch := provider.HardUntrustEpoch()
	if provider.ChallengeShouldStop() {
		return false
	}
	revocationGeneration, _ := s.trustReuseCache.RevocationState(seKey)
	granted := provider.GrantHardwareEvidenceAtEpochIfNotUntrusted(
		registry.DeviceEvidence{
			SEPublicKey:          seKey,
			Serial:               serial,
			VerifiedAt:           s.trustReuseCache.Now(),
			EvidenceGeneration:   1,
			RevocationGeneration: revocationGeneration,
		},
		epoch,
	)
	if granted {
		s.logger.Info("trust-reuse: hardware trust granted without reuse record (no self-reported binary hash)",
			"provider_id", provider.ID)
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
