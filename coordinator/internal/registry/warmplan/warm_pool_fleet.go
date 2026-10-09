package warmplan

// warmColdReason labels why a cold (on-disk, not-warm) provider is or isn't an
// eligible warm-pool target. Empty ("") means eligible. Used to instrument why
// the eligible-cold set is smaller than the raw cold-provider count (e.g. a
// dedicated pool reporting many cold boxes but warming few) — counts only, no
// provider identities, so it is privacy-safe to log/expose.
type ColdReason string

const (
	WarmColdEligible       ColdReason = ""
	WarmColdOfflineUntrust ColdReason = "offline_untrusted_private"
	WarmColdPendingLoad    ColdReason = "pending_load_or_cooldown"
	WarmColdNotIdle        ColdReason = "not_idle"
	WarmColdThermal        ColdReason = "thermal_critical"
	WarmColdTrust          ColdReason = "trust_or_runtime"
	WarmColdStaleChallenge ColdReason = "stale_challenge"
	WarmColdNotServing     ColdReason = "not_serving_catalog"
	WarmColdDedicated      ColdReason = "dedicated_excluded"
	WarmColdTooLarge       ColdReason = "model_too_large"
	WarmColdNoFreeForLoad  ColdReason = "no_free_for_load"
	WarmColdStateRestoring ColdReason = "state_restoring"
	WarmColdDwell          ColdReason = "placement_dwell"
	WarmColdAutopilot      ColdReason = "autopilot_managed"
)

// warmColdReasonStrings converts a reason tally to a string-keyed map for
// logging / the snapshot. Returns nil for an empty tally.
func ColdReasonStrings(in map[ColdReason]int) map[string]int {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]int, len(in))
	for reason, n := range in {
		out[string(reason)] = n
	}
	return out
}
