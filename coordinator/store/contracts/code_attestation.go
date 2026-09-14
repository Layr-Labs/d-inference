package contracts

import (
	"context"
	"time"
)

// CodeAttestation is the persistent representation of one device's most recent
// successful APNs code-identity attestation (W5 Fix 2). It is the durable form
// of api.codeAttestRecord. Keyed by the Secure Enclave public key — the stable
// per-device identity that survives reconnects AND coordinator restarts.
//
// SECURITY: the row is written ONLY after a full, verified code-identity
// round-trip; it is never created from an unverified heartbeat token. On read,
// reuse still checks exact identity and either proof freshness or coordinator-
// observed same-process continuity. Coverage never changes AttestedAt or grants
// trust: a fresh encrypted process-possession challenge is always required.
type CodeAttestation struct {
	// Coordinator-observed continuity of this exact verified application process.
	ContinuousCoverageUntil *time.Time `json:"continuous_coverage_until,omitempty"`
	SEPubKey                string     `json:"se_pubkey"`       // base64 Secure Enclave P-256 public key (bound at registration)
	Version                 string     `json:"version"`         // provider binary version that attested
	AttestedAt              time.Time  `json:"attested_at"`     // instant of the successful round-trip
	APNsToken               string     `json:"apns_token"`      // APNs token the proof was bound to; empty legacy rows require a fresh real push.
	NodePublicKey           string     `json:"node_public_key"` // registration X25519 process key; protected-capability reuse requires exact match
	BinaryHash              string     `json:"binary_hash"`     // SE-attested binary identity (SHA-256 hex) the proof was earned under; empty legacy rows never authorize a release-transition resume
}

// CodeAttestPushBudget is durable APNs admission metadata, not evidence. It
// prevents a coordinator restart or blue-green overlap from forgetting a push
// already spent for one Secure Enclave identity. TokenHash distinguishes a real
// APNs token rotation without persisting another copy of the token.
//
// The row with TokenHash == "" is the per-SE-key ADMISSION FLOOR: the earliest
// instant a push to a NOVEL (previously unbudgeted) token may be admitted.
// Every admitted push raises it, so a device's first-ever token pushes
// immediately while a churn of fabricated fresh tokens is paced at the same
// per-device budget as a single token (Codex P1). A genuine mid-connection
// rotation clears it via ClearCodeAttestPushFloor, preserving prompt
// re-challenge (Codex #9).
//
// The sentinel additionally records LastClearAt — the DURABLE instant of the
// last honored rotation clear. ClearCodeAttestPushFloor compare-and-sets on it,
// clearing only when the previous durable clear is at least the caller's
// cooldown old, so the anti-abuse spacing between rotation clears survives
// coordinator restarts and blue-green overlap (a fresh instance's empty
// process-local throttle map can no longer grant one free floor clear per
// deploy).
//
// Novel-token admission is SERIALIZED on the sentinel: an implementation must
// atomically create-or-advance the sentinel first and admit the token row only
// when that acquisition succeeded, so two coordinators (blue-green overlap)
// racing distinct novel tokens for one SE key admit exactly one — the loser
// observes the winner's raised floor. MemoryStore gets this from its single
// process-wide mutex; PostgresStore takes the sentinel row's ON CONFLICT lock
// before inserting the token row.
type CodeAttestPushBudget struct {
	SEPubKey   string
	TokenHash  string // "" = per-SE-key admission-floor sentinel, not a token row
	NextPushAt time.Time
	UpdatedAt  time.Time
	// LastClearAt is meaningful only on the TokenHash=="" sentinel: the instant
	// of the last honored rotation floor clear (zero = never cleared). Kept
	// when the floor is re-raised by later admissions.
	LastClearAt time.Time
}

// CodeAttestPushBudgetMaxTokenRows caps durable per-token budget rows kept per
// Secure Enclave key. Admission keeps the most recently used rows; an evicted
// token that returns (deep A-B-A) is treated as novel and paced by the
// admission floor instead of its exact historical cooldown. Bounds table growth
// and the startup seed map against unbounded token fabrication.
const CodeAttestPushBudgetMaxTokenRows = 8

// CodeAttestationStore persists reusable application identity proofs.
type CodeAttestationStore interface {
	// --- APNs code-identity attestation reuse cache (survives deploys) ---

	// ListCodeAttestations returns all persisted code-identity attestation
	// records (for seeding the in-memory reuse cache at startup).
	ListCodeAttestations(ctx context.Context) ([]CodeAttestation, error)

	// UpsertCodeAttestation creates or updates the attestation record for a
	// device (keyed by SEPubKey). Called after a successful code-identity
	// round-trip; best-effort, must not block the read loop.
	UpsertCodeAttestation(ctx context.Context, rec CodeAttestation) error

	// DeleteCodeAttestation removes a device's persisted attestation record
	// (keyed by SEPubKey). Called when the device's APNs token CHANGES so a later
	// coordinator restart cannot reseed and reuse the pre-rotation proof — keeping
	// the "token change forces a real re-challenge" invariant durable across
	// restarts. Best-effort; must not block the read loop.
	DeleteCodeAttestation(ctx context.Context, seKey string) error
}
