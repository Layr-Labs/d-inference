package forecast

import "time"

// CacheBenefit prices an already authenticated cache observation. Identity and
// generation validation remain with the registry before this value is supplied.
type CacheBenefit struct {
	Tokens, Weight, RestoreMS float64
	ExpiresAt                 time.Time
}

func (c CacheBenefit) Apply(request *Request, now time.Time) {
	if !c.ExpiresAt.IsZero() && now.Before(c.ExpiresAt) {
		request.CachedTokens = min(float64(request.PromptTokens), c.Tokens) * c.Weight
		request.RestoreMS = c.RestoreMS
	}
}
