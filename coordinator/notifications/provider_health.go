package notifications

import (
	"fmt"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"golang.org/x/mod/semver"
)

type providerHealthAssessor struct {
	minProviderVersion string
	minTrustLevel      registry.TrustLevel
}

func (a providerHealthAssessor) reasons(p providerState, now time.Time) []AlertReason {
	providerVersion := semverCanonical(p.version)
	minVersion := semverCanonical(a.minProviderVersion)
	out := make([]AlertReason, 0, maxProviderAlertReasons)
	if !p.online && now.Sub(p.lastSeen) >= providerHeartbeatTimeout {
		out = append(out, AlertReason{
			Key:    alertReasonOffline,
			Title:  "Machine offline",
			Detail: fmt.Sprintf("No heartbeat since %s.", p.lastSeen.UTC().Format(time.RFC822)),
			Action: "Start the provider with `darkbloom start` or check the machine/network.",
		})
	}
	if providerVersion != "" && minVersion != "" && semver.Compare(providerVersion, minVersion) < 0 {
		out = append(out, AlertReason{
			Key:    alertReasonVersionBelowMin,
			Title:  "Provider update required",
			Detail: fmt.Sprintf("This machine is on v%s; the coordinator requires v%s or newer.", p.version, a.minProviderVersion),
			Action: "Update with the Darkbloom install script, then restart the provider.",
		})
	}
	if !p.runtimeVerified {
		out = append(out, AlertReason{
			Key:    alertReasonRuntimeUnverified,
			Title:  "Runtime verification failed",
			Detail: "The provider runtime hashes do not match the known-good release manifest.",
			Action: "Reinstall with the latest Darkbloom installer to restore routing eligibility.",
		})
	}
	if p.thermalState == "critical" {
		out = append(out, AlertReason{
			Key:    alertReasonThermalCritical,
			Title:  "Machine is thermally throttled",
			Detail: "The Mac reported a critical thermal state, so the coordinator will not route work to it.",
			Action: "Cool the machine and make sure it has adequate ventilation.",
		})
	}
	if p.online && p.lastChallengeVerified != nil && p.status != registry.StatusUntrusted && now.Sub(*p.lastChallengeVerified) > challengeMaxAge {
		out = append(out, AlertReason{
			Key:    alertReasonChallengeStale,
			Title:  "Attestation challenge stale",
			Detail: fmt.Sprintf("The last verified attestation challenge was %d minutes ago.", int(now.Sub(*p.lastChallengeVerified).Minutes())),
			Action: "Restart the provider so it can complete a fresh attestation handshake.",
		})
	}
	if p.status == registry.StatusUntrusted || p.failedChallenges >= registry.MaxFailedChallenges {
		out = append(out, AlertReason{
			Key:    alertReasonUntrusted,
			Title:  "Attestation challenge failures",
			Detail: fmt.Sprintf("%d consecutive challenge failures; this machine is not receiving requests.", p.failedChallenges),
			Action: "Restart the provider and run `darkbloom doctor` if it does not recover.",
		})
	}
	if p.status != registry.StatusUntrusted && p.failedChallenges < registry.MaxFailedChallenges && trustRank(p.trustLevel) < trustRank(a.minTrustLevel) {
		out = append(out, AlertReason{
			Key:    alertReasonTrustBelowMinimum,
			Title:  "MDM enrollment or hardware verification required",
			Detail: fmt.Sprintf("This machine is %s trust; public routing requires %s trust.", displayTrust(p.trustLevel), displayTrust(a.minTrustLevel)),
			Action: "Run `darkbloom enroll` on the Mac and approve the Darkbloom device-management profile.",
		})
	}
	return out
}

func semverCanonical(v string) string {
	v = "v" + strings.TrimPrefix(strings.TrimSpace(v), "v")
	if v == "v" || !semver.IsValid(v) {
		return ""
	}
	return v
}
