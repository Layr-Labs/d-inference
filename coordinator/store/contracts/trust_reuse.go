package contracts

import (
	"context"
	"time"
)

// ProviderTrustReuse is durable device evidence, not a credential. A row can
// only avoid a redundant MDM round-trip after a fresh registration-bound
// Secure-Enclave challenge proves the current process key and posture.
//
// HardwareProofVerifiedAt is the independent MDM/MDA clock. The application
// clock is audit-only here: current application evidence is connection-scoped
// and must be recreated from a fresh signed challenge after every reconnect.
// LastVerifiedBinaryHash is retained for same-binary decisions and audit, but a
// changed hash is admitted only by the server's active-release policy snapshot.
//
// ContinuousCoverageUntil is the coordinator-measured liveness watermark: the
// last instant the coordinator itself observed this device connected and
// hardware-trusted on a live SE-challenged connection anchored at a full live
// verification or a valid reuse grant. It is written ONLY by the coordinator
// (batched periodic advance + graceful-shutdown/disconnect sweep), never from
// any provider-supplied value, and it is monotonic: an advance can never move
// it backward and never touches a tombstoned or non-hardware row. A reconnect
// whose offline gap (now - ContinuousCoverageUntil) is below the physical
// RecoveryOS floor proves the device cannot have flipped SIP/Secure Boot in
// between (entering and leaving Recovery takes >= ~3 minutes and drops the
// WebSocket), so evidence may be reused without a live MDM round.
//
// RevocationGeneration, RevocationEventID, and RevokedAt form a durable
// monotonic tombstone. RevocationEventID identifies one hard-untrust operation:
// retrying that event is idempotent, while a different event advances the
// generation even when its coordinator observed stale state. Normal upserts
// cannot clear the tombstone; only RecoverProviderTrustReuse, called by the
// reviewed full-device verification path, may clear it at the exact observed
// generation.
type ProviderTrustReuse struct {
	SEPubKey                   string     `json:"se_pubkey"`
	Serial                     string     `json:"serial"`
	TrustLevel                 string     `json:"trust_level"`
	LastVerifiedBinaryHash     string     `json:"last_verified_binary_hash"`
	SIPEnabled                 bool       `json:"sip_enabled"`
	SecureBootFull             bool       `json:"secure_boot_full"`
	MDAUDID                    string     `json:"mda_udid"`
	HardwareProofVerifiedAt    time.Time  `json:"hardware_proof_verified_at"`
	ApplicationProofVerifiedAt *time.Time `json:"application_proof_verified_at,omitempty"`
	ContinuousCoverageUntil    *time.Time `json:"continuous_coverage_until,omitempty"`
	EvidenceGeneration         uint64     `json:"evidence_generation"`
	RevocationGeneration       uint64     `json:"revocation_generation"`
	RevocationEventID          string     `json:"revocation_event_id"`
	RevokedAt                  *time.Time `json:"revoked_at,omitempty"`
}

// ProviderTrustReuseWriteResult is the authoritative outcome of a
// generation-checked evidence write. Applied is false when a newer durable
// revocation won; callers must never grant hardware in that case. The returned
// generations always reflect the durable row, including an insert/update that
// committed successfully.
type ProviderTrustReuseWriteResult struct {
	Applied              bool
	EvidenceGeneration   uint64
	RevocationGeneration uint64
}

// TrustReuseStore owns durable proof generations and revocation tombstones.
type TrustReuseStore interface {
	// --- Durable provider device evidence ---

	ListProviderTrustReuse(ctx context.Context) ([]ProviderTrustReuse, error)

	// UpsertProviderTrustReuse records a normal successful full-device proof at
	// the caller's expected revocation generation. It never clears a durable
	// tombstone and returns the authoritative durable generations.
	UpsertProviderTrustReuse(ctx context.Context, rec ProviderTrustReuse, expectedRevocationGeneration uint64) (ProviderTrustReuseWriteResult, error)

	// RecoverProviderTrustReuse is the only store operation allowed to clear a
	// tombstone. It succeeds only when expectedRevocationGeneration still equals
	// the durable generation, so a raced hard-untrust wins.
	RecoverProviderTrustReuse(ctx context.Context, rec ProviderTrustReuse, expectedRevocationGeneration uint64) (ProviderTrustReuseWriteResult, error)

	// AdvanceProviderTrustReuseCoverage batch-advances the coordinator-measured
	// continuous-coverage watermark for the given identities in one write pass.
	// Monotonic and fail-safe: it never moves a watermark backward, and it
	// skips tombstoned or non-hardware rows entirely (a revocation tombstone
	// wins; coverage never resurrects evidence).
	AdvanceProviderTrustReuseCoverage(ctx context.Context, seKeys []string, until time.Time) error

	// RevokeProviderTrustReuse atomically installs one durable hard-untrust event.
	// Retrying the same non-empty event ID returns the authoritative existing row
	// unchanged, including after an ambiguous commit. A different event ID always
	// advances the durable generation and tombstones the row, regardless of stale
	// coordinator state.
	RevokeProviderTrustReuse(ctx context.Context, seKey, revocationEventID string) (ProviderTrustReuse, error)
}
