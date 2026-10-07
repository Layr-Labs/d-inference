package store

import (
	"context"
	"time"
)

// AppAttestKeyRotationStore records coordinator-requested retirement of a dead
// App Attest key. Discover it through As so CachedStore does not hide it. A
// rotation record never revokes a key, denies serving or grants trust; a
// replacement key must complete the normal attestation and assertion checks.
type AppAttestKeyRotationStore interface {
	// RecordAppAttestKeyRotation inserts at most one record per key and
	// reports whether this call inserted it.
	RecordAppAttestKeyRotation(context.Context, AppAttestKeyRotation) (bool, error)
	// AdmitAppAttestKeyRotation atomically applies the per-scope limits and
	// inserts r. Canonical resolution, limits and insertion are serialized
	// with machine merges and admissions for that canonical scope. Stale
	// pre-merge IDs share the survivor's budget, including all merged history.
	// A key that already has a record is returned as
	// existing without checking limits or inserting (it names the same dead
	// key). When any limit is full nothing is inserted and admitted is false.
	AdmitAppAttestKeyRotation(ctx context.Context, r AppAttestKeyRotation, limits []AppAttestRotationLimit) (existing *AppAttestKeyRotation, admitted bool, err error)
	// CountAppAttestKeyRotations counts records for one rate-limit scope
	// (canonical machine, or the account fallback) requested at or after since,
	// including records stored under machines merged into it.
	CountAppAttestKeyRotations(ctx context.Context, machineID string, since time.Time) (int, error)
	GetAppAttestKeyRotation(ctx context.Context, keyID string) (*AppAttestKeyRotation, error)
	// CountAppAttestRotationFailures counts archived assertion failures that
	// suggest a dead Secure Enclave key: outcome apple_error with no native
	// error, or DeviceCheck code 0 or 2. Only rows whose coordinator-expected
	// key matches keyID count, so a client cannot charge another key.
	// The result saturates at AppAttestRotationCountCap.
	CountAppAttestRotationFailures(ctx context.Context, keyID string, since time.Time) (int, error)
	// AppAttestEnrollmentInvalidKeyFailureTimes returns when attestation
	// replies with outcome apple_invalid_key were received since since, from
	// sessions currently attributed to machineID, or to accountID when
	// machineID is empty. Newest first, at most AppAttestRotationCountCap.
	AppAttestEnrollmentInvalidKeyFailureTimes(ctx context.Context, machineID, accountID string, since time.Time) ([]time.Time, error)
}

type AppAttestKeyRotation struct {
	KeyID       string
	MachineID   string // rate-limit scope: canonical machine ID or "account:<id>"
	AccountID   string
	RequestedAt time.Time
	Failures    int
	Reason      string
}

// AppAttestRotationLimit caps rotations for one scope within a trailing window.
type AppAttestRotationLimit struct {
	Window time.Duration
	Max    int
}

// AppAttestRotationCountCap bounds failure-count queries; callers compare
// against small thresholds, so an exact count is never needed.
const AppAttestRotationCountCap = 100
