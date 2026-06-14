package notifications

import (
	"sort"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"golang.org/x/mod/semver"
)

func providerStateFromRecord(rec store.ProviderRecord) providerState {
	return providerState{
		id:                    rec.ID,
		accountID:             rec.AccountID,
		serial:                rec.SerialNumber,
		version:               rec.Version,
		status:                registry.StatusOffline,
		trustLevel:            rec.TrustLevel,
		runtimeVerified:       rec.RuntimeVerified,
		lastSeen:              rec.LastSeen,
		lastChallengeVerified: rec.LastChallengeVerified,
		failedChallenges:      rec.FailedChallenges,
		online:                false,
	}
}

func providerStateFromLive(p *registry.Provider, rec store.ProviderRecord) providerState {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	var lastChallenge *time.Time
	if !p.LastChallengeVerified.IsZero() {
		t := p.LastChallengeVerified
		lastChallenge = &t
	}
	serial := rec.SerialNumber
	if p.AttestationResult != nil && p.AttestationResult.SerialNumber != "" {
		serial = p.AttestationResult.SerialNumber
	}
	accountID := p.AccountID
	if accountID == "" {
		accountID = rec.AccountID
	}
	return providerState{
		id:                    p.ID,
		accountID:             accountID,
		serial:                serial,
		version:               p.Version,
		status:                p.Status,
		trustLevel:            string(p.TrustLevel),
		runtimeVerified:       p.RuntimeVerified,
		thermalState:          p.SystemMetrics.ThermalState,
		lastSeen:              p.LastHeartbeat,
		lastChallengeVerified: lastChallenge,
		failedChallenges:      p.FailedChallenges,
		online:                true,
	}
}

func notificationStableKey(rec store.ProviderRecord) string {
	if rec.SerialNumber != "" {
		return "serial:" + rec.SerialNumber
	}
	if rec.SEPublicKey != "" {
		return "sekey:" + rec.SEPublicKey
	}
	return "provider:" + rec.ID
}

func providerDisplayName(p providerState) string {
	if p.serial != "" {
		if len(p.serial) > 6 {
			return "Mac " + p.serial[len(p.serial)-6:]
		}
		return "Mac " + p.serial
	}
	if p.id != "" && len(p.id) >= 8 {
		return "provider " + p.id[:8]
	}
	return "provider"
}

func reasonKeys(reasons []AlertReason) []string {
	keys := make([]string, 0, len(reasons))
	for _, r := range reasons {
		keys = append(keys, string(r.Key))
	}
	sort.Strings(keys)
	return keys
}

func displayTrust(level string) string {
	if level == "" {
		return "none"
	}
	return strings.ReplaceAll(level, "_", " ")
}

func trustRank(level string) int {
	switch registry.TrustLevel(level) {
	case registry.TrustHardware:
		return 2
	case registry.TrustSelfSigned:
		return 1
	default:
		return 0
	}
}

func semverLess(a, b string) bool {
	a = normalizeSemver(a)
	b = normalizeSemver(b)
	return semver.IsValid(a) && semver.IsValid(b) && semver.Compare(a, b) < 0
}

func normalizeSemver(v string) string {
	v = strings.TrimSpace(v)
	if v == "" {
		return ""
	}
	if !strings.HasPrefix(v, "v") {
		v = "v" + v
	}
	return v
}
