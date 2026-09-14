package warmpool

type FleetModel struct {
	Model         string
	Warm          int
	WarmSaturated int
	// warmForeignBlocked is the subset of warmSaturated whose saturation is NOT
	// explained by this model's own load: the provider has the weights resident
	// but zero concurrency headroom while running NONE of this model's requests,
	// so a co-resident model consumed its capacity. Those requests are absent
	// from this model's running/waiting, so such a provider contributes qc to
	// nominal capacity while being able to serve nothing — see headroomTarget.
	WarmForeignBlocked int
	// running / waiting are the in-flight load summed across warm providers'
	// backend slots for this model (the observable L in Little's Law).
	Running int
	Waiting int
	// soloDecodeTPS / serviceDecodeTPS / prefillTPS / maxProviderConc are
	// representative (median) rates and the per-provider concurrency cap across
	// providers serving the model. soloDecodeTPS is the STATIC solo rate from
	// the quality-cap resolver (resolvedSoloModelTPSLocked) and feeds quality
	// concurrency, so warm targets and admission caps use the same math and
	// cannot disagree. serviceDecodeTPS keeps the observed-EWMA-preferring
	// chain (resolvedModelTPSLocked) and feeds only the E[S] service-time
	// estimate, which deliberately wants the load-inclusive rate a request
	// actually sees.
	SoloDecodeTPS    float64
	ServiceDecodeTPS float64
	PrefillTPS       float64
	MaxProviderConc  int
	EligibleCold     []Candidate
	// coldIneligible / coldDisq tally cold (on-disk, not-warm) providers that
	// FAILED the warm-pool candidate gate, by reason — diagnostics for why
	// eligibleCold is smaller than the raw cold count.
	ColdIneligible    int
	ColdDisqualifiers map[ColdReason]int
}

type Candidate struct {
	ProviderID string
	Score      float64
}

// warmColdReason labels why a cold (on-disk, not-warm) provider is or isn't an
// eligible warm-pool target. Empty ("") means eligible. Used to instrument why
// the eligible-cold set is smaller than the raw cold-provider count (e.g. a
// dedicated pool reporting many cold boxes but warming few) — counts only, no
// provider identities, so it is privacy-safe to log/expose.
type ColdReason string

const (
	ColdEligible       ColdReason = ""
	ColdOfflineUntrust ColdReason = "offline_untrusted_private"
	ColdPendingLoad    ColdReason = "pending_load_or_cooldown"
	ColdNotIdle        ColdReason = "not_idle"
	ColdThermal        ColdReason = "thermal_critical"
	ColdTrust          ColdReason = "trust_or_runtime"
	ColdStaleChallenge ColdReason = "stale_challenge"
	ColdNotServing     ColdReason = "not_serving_catalog"
	ColdDedicated      ColdReason = "dedicated_excluded"
	ColdTooLarge       ColdReason = "model_too_large"
	ColdNoFreeForLoad  ColdReason = "no_free_for_load"
	ColdStateRestoring ColdReason = "state_restoring"
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
