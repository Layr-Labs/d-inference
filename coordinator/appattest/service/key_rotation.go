package service

import (
	"context"
	"crypto/rand"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Released clients retire an accepted key only on an explicit invalid-key
// error, but a Secure Enclave key that died across a reboot or OS update fails
// every assertion with DeviceCheck code 0 (or an uncoded apple_error). When the
// durable archive shows repeated such failures since the key's last verified
// assertion, the coordinator answers the next ready with attest instead of
// assert. Released clients answer attest for an attested key with
// key_unregistered and generate a replacement under their own budget. The
// replacement must pass the full attestation and assertion checks; the dead
// key is retired, never revoked, and no serving permission changes here.
const (
	keyRotationFailureThreshold = 2
	keyRotationHourlyLimit      = 1
	keyRotationDailyLimit       = 4
	keyRotationRetryMin         = 15 * time.Second
	keyRotationRetrySpread      = 31 // seconds; delays are 15–45 s
)

// maybeRequestKeyRotation runs on a ready reply for a known, owner-matched key.
// It returns true only after durably recording a rotation request.
func (x *Session) maybeRequestKeyRotation(ctx context.Context, key *store.AppAttestShadowKey) bool {
	if x.protocolVersion < 2 {
		return false
	}
	rotations, ok := store.As[store.AppAttestKeyRotationStore](x.s.store)
	if !ok {
		return false
	}
	failures, err := rotations.CountAppAttestRotationFailures(ctx, key.KeyID, key.UpdatedAt)
	if err != nil {
		x.observeKeyRotation("storage_error")
		return false
	}
	if failures < keyRotationFailureThreshold {
		return false
	}
	scope, decision := x.keyRotationPermitted(ctx, rotations, key)
	if decision != "permitted" {
		x.observeKeyRotation(decision)
		return false
	}
	inserted, err := rotations.RecordAppAttestKeyRotation(ctx, store.AppAttestKeyRotation{KeyID: key.KeyID, MachineID: scope, AccountID: x.account,
		RequestedAt: time.Now().UTC(), Failures: failures, Reason: "assertion_apple_error"})
	if err != nil {
		x.observeKeyRotation("storage_error")
		return false
	}
	// A repeat request for an already recorded key (its earlier attest frame
	// was lost, or the client kept the key) inserts nothing and passed the
	// rate limits above. Only a newly recorded rotation earns the short retry
	// after key_unregistered; a repeat keeps the normal bounded backoff, so a
	// client that never retires the key cannot drive a fast loop.
	x.rotationRequested = inserted
	x.observeKeyRotation("requested")
	return true
}

// keyRotationPermitted applies the cohort and per-machine rate limits. It
// returns the rate-limit scope and "permitted" or the blocking outcome. A
// key that already has a rotation record may be asked again (its attest frame
// may have been lost): that re-names the same dead key, so it cannot make the
// client generate more than one replacement for it.
func (x *Session) keyRotationPermitted(ctx context.Context, rotations store.AppAttestKeyRotationStore, key *store.AppAttestShadowKey) (string, string) {
	switch appAttestKeyRotationCohortDecision(x.account, x.s.config.KeyRotationPercent) {
	case "enabled":
	case "configuration_error":
		return "", "configuration_error"
	default:
		return "", "cohort_excluded"
	}
	existing, err := rotations.GetAppAttestKeyRotation(ctx, key.KeyID)
	if err != nil {
		return "", "storage_error"
	}
	if existing != nil {
		return existing.MachineID, "permitted"
	}
	scope := "account:" + x.account
	if machine := x.canonicalMachine(ctx, key.MachineID); machine != "" {
		scope = machine
	}
	now := time.Now().UTC()
	hourly, err := rotations.CountAppAttestKeyRotations(ctx, scope, now.Add(-time.Hour))
	if err != nil {
		return scope, "storage_error"
	}
	daily, err := rotations.CountAppAttestKeyRotations(ctx, scope, now.Add(-24*time.Hour))
	if err != nil {
		return scope, "storage_error"
	}
	if hourly >= keyRotationHourlyLimit || daily >= keyRotationDailyLimit {
		return scope, "rate_limited"
	}
	return scope, "permitted"
}

// canonicalMachine resolves this connection's machine, falling back to the
// credential's recorded machine, through canonical merges. Empty means no
// machine identity is known and callers scope limits to the account.
func (x *Session) canonicalMachine(ctx context.Context, fallback string) string {
	machine := x.machineID()
	if machine == "" {
		machine = fallback
	}
	if machine == "" {
		return ""
	}
	if lookup, ok := store.As[store.MachineIdentityLookupStore](x.s.store); ok {
		if canonical, err := lookup.CanonicalMachineID(ctx, machine); err == nil && canonical != "" {
			return canonical
		}
	}
	return machine
}

// rotationRetryDue reports whether the exchange that just failed should be
// retried after a short delay: the client answered a rotation request from
// this session, or an assertion failure brought the durable count to the
// threshold while a rotation is currently permitted. Rate-limited or excluded
// machines keep the normal bounded backoff, so this cannot loop quickly.
func (x *Session) rotationRetryDue(failure string) bool {
	if failure == "key_unregistered" && x.rotationRequested {
		return true
	}
	if failure != "apple_error" || x.expected != "assertion" || x.key == nil || x.protocolVersion < 2 {
		return false
	}
	rotations, ok := store.As[store.AppAttestKeyRotationStore](x.s.store)
	if !ok {
		return false
	}
	release, ok := x.acquireStorage()
	if !ok {
		return false
	}
	defer release()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	failures, err := rotations.CountAppAttestRotationFailures(ctx, x.key.KeyID, x.key.UpdatedAt)
	if err != nil || failures < keyRotationFailureThreshold {
		return false
	}
	_, decision := x.keyRotationPermitted(ctx, rotations, x.key)
	return decision == "permitted"
}

func keyRotationRetryDelay() time.Duration {
	var b [1]byte
	_, _ = rand.Read(b[:])
	return keyRotationRetryMin + time.Duration(int(b[0])%keyRotationRetrySpread)*time.Second
}

func (x *Session) observeKeyRotation(outcome string) {
	x.s.ddIncr("app_attest.key_rotation", []string{"outcome:" + outcome})
	x.observeSideEffect("rotation", outcome)
}

// observeSideEffect records an intermediate decision without replacing the
// exchange outcome used by the retry loop or pending evidence completion.
func (x *Session) observeSideEffect(stage, outcome string) {
	last, evidence := x.lastOutcome, x.evidenceOutcome
	x.observe(stage, outcome, nil)
	x.lastOutcome, x.evidenceOutcome = last, evidence
}
