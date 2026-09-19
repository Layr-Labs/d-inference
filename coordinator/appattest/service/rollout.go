package service

import (
	"crypto/sha256"
	"encoding/binary"
	"strings"

	"golang.org/x/mod/semver"
)

// Never send an Apple operation to the released 0.9.3 callback timer. This is
// an operational version floor, not evidence that a client runs approved code.
const appAttestSafeProviderVersion = "0.9.4"

func appAttestRolloutDecision(version, account, machine string, percent int) string {
	decision := appAttestAccountRolloutDecision(version, account, percent)
	if decision != "provider_upgrade_required" && machine == "" {
		return "identity_required"
	}
	return decision
}

// Account membership is known at authenticated registration, before a canonical
// machine ID exists. Both identity admission and the later exchange use this
// exact cohort decision; a claimed serial or provisional ID never chooses it.
func appAttestAccountRolloutDecision(version, account string, percent int) string {
	if !appAttestProviderVersionSafe(version) {
		return "provider_upgrade_required"
	}
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

func appAttestProviderVersionSafe(version string) bool {
	v := "v" + strings.TrimPrefix(version, "v")
	return semver.IsValid(v) && semver.Compare(v, "v"+appAttestSafeProviderVersion) >= 0
}
