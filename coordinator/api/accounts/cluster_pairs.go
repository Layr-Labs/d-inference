package accounts

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	fleetview "github.com/eigeninference/d-inference/coordinator/internal/api/accounts/fleetview"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// HandleMyClusterPairs lists the caller's own two-Mac clusters and where each
// stands. It never reports another account's cluster or member.
func (s *Owner) HandleMyClusterPairs(w http.ResponseWriter, r *http.Request) {
	user := access.RequirePrivyUser(w, r)
	if user == nil {
		return
	}
	views, enabled := s.listClusterPairs()
	httpx.WriteJSON(w, http.StatusOK, fleetview.ClusterPairsResponse{
		Enabled: enabled, RequestScope: registry.ClusterPairRequestScope(),
		LifetimeSeconds: int(registry.ClusterPairLifetime() / time.Second),
		Pairs:           fleetview.ClusterPairs(views, user.AccountID, time.Now()),
	})
}

func (s *Owner) listClusterPairs() ([]registry.NativePairView, bool) {
	if s.clusterPairs == nil {
		return nil, false
	}
	return s.clusterPairs()
}
