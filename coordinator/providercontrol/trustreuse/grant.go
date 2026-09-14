package trustreuse

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
	"time"
)

// RecordVerified persists a reviewed, synchronous full MDM/MDA verification.
// It is the only path allowed to clear a durable revocation tombstone, and then
// only at the exact generation observed before the write. A concurrent hard
// untrust increments that generation and wins both the store CAS and the
// provider epoch checks.
func (s *Manager) RecordVerified(provider *registry.Provider, seKey, serial, binaryHash string, sipEnabled, secureBootFull bool, udid string) bool {
	return s.recordTrustReuseAtGeneration(provider, seKey, serial, binaryHash, sipEnabled, secureBootFull, udid, true)
}

// RecordLate records a late MDM/APNs callback without revocation
// recovery authority. A tombstoned row or cache entry remains tombstoned.
func (s *Manager) RecordLate(provider *registry.Provider, seKey, serial, binaryHash string, sipEnabled, secureBootFull bool, udid string) bool {
	return s.recordTrustReuseAtGeneration(provider, seKey, serial, binaryHash, sipEnabled, secureBootFull, udid, false)
}

func (s *Manager) recordTrustReuseAtGeneration(provider *registry.Provider, seKey, serial, binaryHash string, sipEnabled, secureBootFull bool, udid string, allowRecovery bool) bool {
	if s == nil || s.cache == nil || provider == nil ||
		seKey == "" || serial == "" {
		return false
	}
	if blocked, _ := s.SafetyStatus(); blocked || s.trustReuseIdentityPending(seKey) {
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
	normHash, err := s.normalizeHash(binaryHash, "binary_hash")
	if err != nil {
		return false
	}
	expectedRevocationGeneration, revocationEventID := s.cache.revocationState(seKey)
	now := s.cache.now()
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

	st := s.cache.store
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
			s.cache.installRevocationGeneration(
				seKey, writeResult.RevocationGeneration)
			return false
		}
		rec.EvidenceGeneration = writeResult.EvidenceGeneration
		rec.RevocationGeneration = writeResult.RevocationGeneration
	} else {
		rec.EvidenceGeneration = 1
	}

	if allowRecovery {
		s.cache.recoverTrust(rec, rec.RevocationGeneration)
	} else {
		s.cache.recordTrust(rec)
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
		s.MarkCoverage(seKey, provider.ID)
		return true
	}
	if provider.HardUntrustEpoch() == epoch {
		return false
	}
	revocationEventID = uuid.NewString()
	s.cache.invalidateReuse(seKey, revocationEventID)
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
func (s *Manager) grantDeviceTrustWithoutReuseRecord(provider *registry.Provider, seKey, serial string, allowRecovery bool) bool {
	if !allowRecovery && s.cache.isRevoked(seKey) {
		return false
	}
	epoch := provider.HardUntrustEpoch()
	if provider.ChallengeShouldStop() {
		return false
	}
	revocationGeneration, _ := s.cache.revocationState(seKey)
	granted := provider.GrantHardwareEvidenceAtEpochIfNotUntrusted(
		registry.DeviceEvidence{
			SEPublicKey:          seKey,
			Serial:               serial,
			VerifiedAt:           s.cache.now(),
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
