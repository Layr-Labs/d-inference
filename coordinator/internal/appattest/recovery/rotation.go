package recovery

import (
	"context"
	"crypto/rand"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/cohort"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	RotationFailureThreshold = 2
	RotationHourlyLimit      = 1
	RotationDailyLimit       = 4
	RotationRetryMin         = 15 * time.Second
	rotationRetrySpread      = 31
)

type RotationDependencies struct {
	Store            func() store.AppAttestKeyRotationStore
	Account          string
	Percent          int
	CanonicalMachine func(context.Context, string) string
	Acquire          func() (func(), bool)
	Observe          func(string)
}

// Rotation requests retirement, never revocation or serving permission. The
// store's admission lock, not the advisory retry check, enforces scope limits.
type Rotation struct {
	deps      RotationDependencies
	requested bool
}

func NewRotation(deps RotationDependencies) *Rotation { return &Rotation{deps: deps} }

// BeginAttempt prevents a previous exchange's request from accelerating retries.
func (r *Rotation) BeginAttempt() { r.requested = false }

func (r *Rotation) Request(ctx context.Context, key *store.AppAttestShadowKey) bool {
	st := r.deps.Store()
	if st == nil {
		return false
	}
	failures, err := st.CountAppAttestRotationFailures(ctx, key.KeyID, key.UpdatedAt)
	if err != nil {
		r.observe("storage_error")
		return false
	}
	if failures < RotationFailureThreshold {
		return false
	}
	scope, decision := r.permitted(ctx, st, key)
	if decision != "permitted" {
		r.observe(decision)
		return false
	}
	existing, inserted, err := st.AdmitAppAttestKeyRotation(ctx, store.AppAttestKeyRotation{KeyID: key.KeyID, MachineID: scope, AccountID: r.deps.Account, RequestedAt: time.Now().UTC(), Failures: failures, Reason: "assertion_apple_error"}, RotationLimits())
	if err != nil {
		r.observe("storage_error")
		return false
	}
	if !inserted && existing == nil {
		r.observe("rate_limited")
		return false
	}
	r.requested = inserted
	r.observe("requested")
	return true
}

func RotationLimits() []store.AppAttestRotationLimit {
	return []store.AppAttestRotationLimit{{Window: time.Hour, Max: RotationHourlyLimit}, {Window: 24 * time.Hour, Max: RotationDailyLimit}}
}

func (r *Rotation) permitted(ctx context.Context, st store.AppAttestKeyRotationStore, key *store.AppAttestShadowKey) (string, string) {
	switch cohort.KeyRotation(r.deps.Account, r.deps.Percent) {
	case "enabled":
	case "configuration_error":
		return "", "configuration_error"
	default:
		return "", "cohort_excluded"
	}
	existing, err := st.GetAppAttestKeyRotation(ctx, key.KeyID)
	if err != nil {
		return "", "storage_error"
	}
	if existing != nil {
		return existing.MachineID, "permitted"
	}
	scope := "account:" + r.deps.Account
	if r.deps.CanonicalMachine != nil {
		if machine := r.deps.CanonicalMachine(ctx, key.MachineID); machine != "" {
			scope = machine
		}
	} else if key.MachineID != "" {
		scope = key.MachineID
	}
	now := time.Now().UTC()
	hourly, err := st.CountAppAttestKeyRotations(ctx, scope, now.Add(-time.Hour))
	if err != nil {
		return scope, "storage_error"
	}
	daily, err := st.CountAppAttestKeyRotations(ctx, scope, now.Add(-24*time.Hour))
	if err != nil {
		return scope, "storage_error"
	}
	if hourly >= RotationHourlyLimit || daily >= RotationDailyLimit {
		return scope, "rate_limited"
	}
	return scope, "permitted"
}

func (r *Rotation) RetryDue(failure, expected string, key *store.AppAttestShadowKey) bool {
	if failure == "key_unregistered" && r.requested {
		return true
	}
	if failure != "apple_error" || expected != "assertion" || key == nil {
		return false
	}
	st := r.deps.Store()
	if st == nil {
		return false
	}
	if r.deps.Acquire != nil {
		release, ok := r.deps.Acquire()
		if !ok {
			return false
		}
		defer release()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	failures, err := st.CountAppAttestRotationFailures(ctx, key.KeyID, key.UpdatedAt)
	if err != nil || failures < RotationFailureThreshold {
		return false
	}
	_, decision := r.permitted(ctx, st, key)
	return decision == "permitted"
}

func RotationRetryDelay() time.Duration {
	var b [1]byte
	_, _ = rand.Read(b[:])
	return RotationRetryMin + time.Duration(int(b[0])%rotationRetrySpread)*time.Second
}

func (r *Rotation) observe(outcome string) {
	if r.deps.Observe != nil {
		r.deps.Observe(outcome)
	}
}
