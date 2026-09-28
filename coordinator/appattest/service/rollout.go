package service

import (
	"crypto/sha256"
	"encoding/binary"
)

func appAttestRolloutDecision(account, machine string, percent int) string {
	decision := appAttestAccountRolloutDecision(account, percent)
	if machine == "" {
		return "identity_required"
	}
	return decision
}

// Account membership is known at authenticated registration, before a canonical
// machine ID exists. Both identity admission and the later exchange use this
// exact cohort decision; a claimed serial or provisional ID never chooses it.
func appAttestAccountRolloutDecision(account string, percent int) string {
	if account == "" {
		return "identity_required"
	}
	if percent < 0 || percent > 100 {
		return "configuration_error"
	}
	// Accounts are authenticated before enrollment and survive provisional
	// machine IDs or legacy-key loss. All machines on one account share a
	// cohort; the percentage is of accounts, not a claimed physical census.
	h := sha256.Sum256([]byte("app-attest-rollout-account-v1\x00" + account))
	if int(binary.BigEndian.Uint32(h[:4])%100) >= percent {
		return "cohort_excluded"
	}
	return "enabled"
}

// Coordinator-requested dead-key rotation has its own account cohort so it can
// be rolled out or paused independently of the enrollment cohort above.
func appAttestKeyRotationCohortDecision(account string, percent int) string {
	if percent < 0 || percent > 100 {
		return "configuration_error"
	}
	if account == "" {
		return "cohort_excluded"
	}
	h := sha256.Sum256([]byte("app-attest-key-rotation-account-v1\x00" + account))
	if int(binary.BigEndian.Uint32(h[:4])%100) >= percent {
		return "cohort_excluded"
	}
	return "enabled"
}
