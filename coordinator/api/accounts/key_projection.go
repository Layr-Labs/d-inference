package accounts

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// apiKeyToResponse projects a stored key into its masked API representation,
// computing the current-window spend and remaining budget.
func (s *Controller) apiKeyToResponse(k *store.APIKey) types.APIKeyResponse {
	resp := types.APIKeyResponse{
		ID:            k.ID,
		Name:          k.Name,
		Label:         k.Label,
		Disabled:      k.Disabled,
		LimitReset:    store.NormalizeResetWindow(k.LimitReset),
		RPMLimit:      k.RPMLimit,
		ITPMLimit:     k.ITPMLimit,
		OTPMLimit:     k.OTPMLimit,
		AllowedModels: k.AllowedModels,
		SelfRouteOnly: k.SelfRouteOnly,
		ExpiresAt:     k.ExpiresAt,
		CreatedAt:     k.CreatedAt,
		LastUsedAt:    k.LastUsedAt,
	}
	since := store.KeySpendWindowStart(resp.LimitReset, time.Now())
	spent := s.store().KeySpendSince(k.ID, since)
	resp.UsageUSD = microToUSD(spent)
	if k.LimitMicroUSD != nil {
		limitUSD := microToUSD(*k.LimitMicroUSD)
		resp.LimitUSD = &limitUSD
		remaining := *k.LimitMicroUSD - spent
		if remaining < 0 {
			remaining = 0
		}
		remUSD := microToUSD(remaining)
		resp.RemainingUSD = &remUSD
	}
	return resp
}
