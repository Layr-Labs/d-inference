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
		trustLevel:            parseTrustLevel(rec.TrustLevel),
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
		trustLevel:            p.TrustLevel,
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

func displayTrust(level registry.TrustLevel) string {
	if level == "" {
		return "none"
	}
	return strings.ReplaceAll(string(level), "_", " ")
}

var trustRanks = map[registry.TrustLevel]int{
	registry.TrustNone:       0,
	registry.TrustSelfSigned: 1,
	registry.TrustHardware:   2,
}

func parseTrustLevel(level string) registry.TrustLevel {
	trust := registry.TrustLevel(strings.TrimSpace(level))
	if _, ok := trustRanks[trust]; ok {
		return trust
	}
	return registry.TrustNone
}

func trustRank(level registry.TrustLevel) int {
	return trustRanks[level]
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
