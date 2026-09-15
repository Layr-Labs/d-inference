package api

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
	v := "v" + strings.TrimPrefix(version, "v")
	if !semver.IsValid(v) || semver.Compare(v, "v"+appAttestSafeProviderVersion) < 0 {
		return "provider_upgrade_required"
	}
	if account == "" || machine == "" {
		return "identity_required"
	}
	if percent < 0 || percent > 100 {
		return "configuration_error"
	}
	h := sha256.Sum256([]byte("app-attest-rollout-v1\x00" + account + "\x00" + machine))
	if int(binary.BigEndian.Uint32(h[:4])%100) >= percent {
		return "cohort_excluded"
	}
	return "enabled"
}
