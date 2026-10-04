package keys

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Invalidator is the credential cache shared with authentication middleware.
type Invalidator interface {
	InvalidateAPIKeyCache(string)
	InvalidateAllAPIKeyCache()
}

type Handler struct {
	store store.APIKeyStore
	cache Invalidator
}

func New(st store.APIKeyStore, cache Invalidator) *Handler { return &Handler{store: st, cache: cache} }
func usdToMicro(usd float64) int64                         { return int64(math.Round(usd * 1_000_000)) }
func microToUSD(micro int64) float64                       { return float64(micro) / 1_000_000 }
