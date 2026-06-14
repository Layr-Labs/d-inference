package notifications

import (
	"sort"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func providerStateFrom(rec store.ProviderRecord, live *registry.Provider) providerState {
	if live != nil {
		return providerStateFromLive(rec, live)
	}
	trustLevel, _ := parseTrustLevel(rec.TrustLevel)
	return providerState{
		id:                    rec.ID,
		accountID:             rec.AccountID,
		serial:                rec.SerialNumber,
		version:               rec.Version,
		status:                registry.StatusOffline,
		trustLevel:            trustLevel,
		runtimeVerified:       rec.RuntimeVerified,
		lastSeen:              rec.LastSeen,
		lastChallengeVerified: rec.LastChallengeVerified,
		failedChallenges:      rec.FailedChallenges,
		online:                false,
	}
}

func providerStateFromLive(rec store.ProviderRecord, p *registry.Provider) providerState {
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

func parseTrustLevel(level string) (registry.TrustLevel, bool) {
	trust := registry.TrustLevel(strings.TrimSpace(level))
	switch trust {
	case registry.TrustNone, registry.TrustSelfSigned, registry.TrustHardware:
		return trust, true
	}
	return registry.TrustNone, false
}

func trustRank(level registry.TrustLevel) int {
	switch level {
	case registry.TrustHardware:
		return 2
	case registry.TrustSelfSigned:
		return 1
	default:
		return 0
	}
}
