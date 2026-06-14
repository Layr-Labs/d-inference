package notifications

import (
	"sort"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func providerStateFromRecord(rec store.ProviderRecord) providerState {
	return providerState{
		id:                    rec.ID,
		accountID:             rec.AccountID,
		serial:                rec.SerialNumber,
		version:               rec.Version,
		status:                string(registry.StatusOffline),
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
		status:                string(p.Status),
		trustLevel:            string(p.TrustLevel),
		runtimeVerified:       p.RuntimeVerified,
		thermalState:          p.SystemMetrics.ThermalState,
		lastSeen:              p.LastHeartbeat,
		lastChallengeVerified: lastChallenge,
		failedChallenges:      p.FailedChallenges,
		online:                true,
	}
}

func latestProviderRecords(records []store.ProviderRecord) []store.ProviderRecord {
	byKey := make(map[string]store.ProviderRecord)
	for _, rec := range records {
		key := notificationStableKey(rec)
		prev, ok := byKey[key]
		if !ok || rec.LastSeen.After(prev.LastSeen) {
			byKey[key] = rec
		}
	}
	out := make([]store.ProviderRecord, 0, len(byKey))
	for _, rec := range byKey {
		out = append(out, rec)
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].LastSeen.After(out[j].LastSeen)
	})
	return out
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
		keys = append(keys, r.Key)
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
	ap := parseSemver(a)
	bp := parseSemver(b)
	for i := 0; i < len(ap); i++ {
		if ap[i] < bp[i] {
			return true
		}
		if ap[i] > bp[i] {
			return false
		}
	}
	return false
}

func parseSemver(v string) [3]int {
	v = strings.TrimPrefix(strings.TrimSpace(v), "v")
	parts := strings.Split(v, ".")
	var out [3]int
	for i := 0; i < len(parts) && i < 3; i++ {
		n := 0
		for _, ch := range parts[i] {
			if ch < '0' || ch > '9' {
				break
			}
			n = n*10 + int(ch-'0')
		}
		out[i] = n
	}
	return out
}
