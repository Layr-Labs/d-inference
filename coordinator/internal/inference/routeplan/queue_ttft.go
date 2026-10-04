package routeplan

import (
	"github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"time"
)

func QueueTTFTCeiling(scope dispatch.Scope, deadline time.Duration, hardReject bool) float64 {
	if scope.SelfRouteOnly || scope.PreferOwner || !hardReject {
		return 0
	}
	return float64(deadline.Milliseconds())
}
