package warmplan

type Fleet struct {
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
	SoloDecodeTPS      float64
	ServiceDecodeTPS   float64
	PrefillTPS         float64
	MaxProviderConc    int
	QualityConc        int
	AggregateDecodeTPS float64
	WorkProviders      float64
	EligibleCold       []Candidate
	// coldIneligible / coldDisq tally cold (on-disk, not-warm) providers that
	// FAILED the warm-pool candidate gate, by reason — diagnostics for why
	// eligibleCold is smaller than the raw cold count.
	ColdIneligible int
	ColdDisq       map[ColdReason]int
}

type Candidate struct {
	ProviderID           string
	Score                float64
	RecentResidentModels int
}
