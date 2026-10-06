package firstcontent

// Work contains upper bounds through first content. Incoming output limits are
// deliberately absent: only decode work before the target's first content belongs
// here. Callers retain ownership of the original deadline and physical budgets.
type Work struct {
	PromptTokens              int
	ContextTokens             int
	CacheState                string
	Contention                string
	PrefillTokens             float64
	DecodeTokens              float64
	ActiveRequests            int
	OtherModelRequests        int
	OtherModelServiceFraction float64
	CompetitorProfileIDs      []string
	// Fresh matched observations may lower a reviewed rate, never raise it.
	ObservedPrefillTPS float64
	ObservedDecodeTPS  float64
}

type Prediction struct {
	ExpectedMS     float64
	ConservativeMS float64
	CellIndex      int
}

// Predict returns no bound outside the measured envelope. If reviewed cells
// overlap, the largest conservative bound wins; file order cannot manufacture
// a more optimistic prediction. The same rule is used by provider admission.
func (c *Calibration) Predict(work Work) (Prediction, bool) {
	if c == nil || c.Version != Version || !digest(c.PromptContractID) || !nonnegative(work.PrefillTokens) || !positive(work.DecodeTokens) ||
		work.PromptTokens < 1 || work.ContextTokens < work.PromptTokens || work.ActiveRequests < 1 ||
		work.OtherModelRequests < 0 || work.OtherModelRequests >= work.ActiveRequests ||
		!nonnegative(work.OtherModelServiceFraction) || work.OtherModelServiceFraction > 1 ||
		!sortedIDs(work.CompetitorProfileIDs) {
		return Prediction{}, false
	}
	var result Prediction
	found := false
	for i, cell := range c.Cells {
		if !cell.Valid(max(cell.PromptTokensMax, cell.ContextTokensMax)) || !cell.matches(work) {
			continue
		}
		prefill, decode := cell.PrefillTPS, cell.DecodeTPS
		if positive(work.ObservedPrefillTPS) {
			prefill = min(prefill, work.ObservedPrefillTPS)
		}
		if positive(work.ObservedDecodeTPS) {
			decode = min(decode, work.ObservedDecodeTPS)
		}
		expected := (work.PrefillTokens/prefill + work.DecodeTokens/decode) * 1000
		bound := expected*cell.ErrorRatio + cell.ErrorAdditiveMS
		if !positive(expected) || !positive(bound) {
			return Prediction{}, false
		}
		if !found || bound > result.ConservativeMS {
			result = Prediction{ExpectedMS: expected, ConservativeMS: bound, CellIndex: i}
			found = true
		}
	}
	return result, found
}

func (c Cell) matches(w Work) bool {
	if w.PromptTokens < c.PromptTokensMin || w.PromptTokens > c.PromptTokensMax ||
		w.ContextTokens < c.ContextTokensMin || w.ContextTokens > c.ContextTokensMax ||
		w.CacheState != c.CacheState || w.Contention != c.Contention ||
		w.PrefillTokens > float64(c.MaxPrefillWorkTokens) || w.DecodeTokens > float64(c.MaxDecodeWorkTokens) ||
		w.ActiveRequests > c.MaxActiveRequests || w.OtherModelRequests > c.MaxOtherModelRequests ||
		w.OtherModelServiceFraction > c.MaxOtherModelServiceFraction ||
		len(w.CompetitorProfileIDs) != len(c.CompetitorProfileIDs) {
		return false
	}
	for i, id := range w.CompetitorProfileIDs {
		if id != c.CompetitorProfileIDs[i] {
			return false
		}
	}
	return true
}
