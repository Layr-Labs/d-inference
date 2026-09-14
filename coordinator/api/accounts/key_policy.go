package accounts

import (
	"context"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// KeyModelAllowed returns false when the calling key restricts models via an
// allow-list that does not include the requested model. Account-scoped/legacy
// keys (no key in context) and keys without an allow-list always pass.
func KeyModelAllowed(ctx context.Context, model string) bool {
	k := requestcontext.APIKey(ctx)
	if k == nil || len(k.AllowedModels) == 0 {
		return true
	}
	for _, m := range k.AllowedModels {
		if m == model {
			return true
		}
	}
	return false
}

// CheckKeySpendCap reports whether charging additionalMicroUSD to the calling
// key would exceed its per-key spend cap in the current window. It returns
// (message, ok); ok=false means the request must be rejected with 402. The
// per-account balance ledger is still the hard atomic ceiling — this is the
// soft, per-key sub-cap, enforced against settled usage (so concurrent
// in-flight requests are eventually-consistent, never over the account balance).
func CheckKeySpendCap(ctx context.Context, additionalMicroUSD int64, usage KeyUsage) (string, bool) {
	k := requestcontext.APIKey(ctx)
	if k == nil || k.ID == "" || k.LimitMicroUSD == nil {
		return "", true
	}
	since := store.KeySpendWindowStart(k.LimitReset, time.Now())
	spent := usage.KeySpendSince(k.ID, since)
	if spent+additionalMicroUSD > *k.LimitMicroUSD {
		window := store.NormalizeResetWindow(k.LimitReset)
		if window == store.KeyResetNone {
			window = "total"
		}
		return fmt.Sprintf("API key spend limit reached (%s cap $%.2f, used $%.2f) — raise this key's limit or use another key",
			window, microToUSD(*k.LimitMicroUSD), microToUSD(spent)), false
	}
	return "", true
}
