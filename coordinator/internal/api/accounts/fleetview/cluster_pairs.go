package fleetview

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// ClusterPairsResponse is the owner's view of its two-Mac clusters at
// GET /v1/me/cluster-pairs.
type ClusterPairsResponse struct {
	// Enabled is false while the coordinator has no cluster pair
	// configuration; Pairs is then always empty.
	Enabled bool `json:"enabled"`
	// RequestScope says whose requests a pair serves: "owner_account" means
	// only requests from the account that owns both members, sent with
	// X-Darkbloom-Route: self or prefer (or a self-route-only key).
	RequestScope string `json:"request_scope"`
	// LifetimeSeconds is the fixed lifetime of one pair session. A cluster
	// re-forms after each.
	LifetimeSeconds int           `json:"lifetime_seconds"`
	Pairs           []ClusterPair `json:"pairs"`
}

// ClusterPair is one cluster of the caller's account.
type ClusterPair struct {
	ClusterID    string `json:"cluster_id"`
	PolicySHA256 string `json:"policy_sha256"`
	ApprovalID   string `json:"approval_id,omitempty"`
	Model        string `json:"model,omitempty"`
	// State is waiting, preparing, active or reforming. Waiting says what a
	// waiting or re-forming cluster waits for.
	State   string `json:"state"`
	Waiting string `json:"waiting,omitempty"`
	// ServingReady is true while a request from this account would be handed
	// to the leader now.
	ServingReady bool `json:"serving_ready"`
	// Epoch, PrepareBefore and ExpiresAt describe the current session.
	Epoch         string     `json:"epoch,omitempty"`
	PrepareBefore *time.Time `json:"prepare_before,omitempty"`
	ExpiresAt     *time.Time `json:"expires_at,omitempty"`
	// RemainingLifetimeSeconds is the time left before the current session's
	// fixed lifetime ends, zero when there is no session.
	RemainingLifetimeSeconds int `json:"remaining_lifetime_seconds"`
	// ReformExpectedAt is the coordinator's estimate of when a re-forming
	// cluster starts its next session.
	ReformExpectedAt *time.Time `json:"reform_expected_at,omitempty"`
	// Failures counts consecutive sessions that ended before both members
	// were ready to start; Declines counts consecutive preparations a member
	// declined. RetryAt is when the next attempt is allowed after either.
	Failures int                  `json:"failures"`
	Declines int                  `json:"declines"`
	RetryAt  *time.Time           `json:"retry_at,omitempty"`
	Members  [2]ClusterPairMember `json:"members"` // leader, follower
}

// ClusterPairMember is one rank of a cluster. ProviderID is the id of the
// machine's row in GET /v1/me/providers; device identity is not repeated here.
type ClusterPairMember struct {
	Rank       int    `json:"rank"`
	Role       string `json:"role"`
	Attached   bool   `json:"attached"`
	ProviderID string `json:"provider_id,omitempty"`
	ChipName   string `json:"chip_name,omitempty"`
	MemoryGB   int    `json:"memory_gb,omitempty"`
}

// ExecutionRoleName names a connection's role for the dashboard. The wire
// leaves an ordinary provider's role empty; the dashboard calls it "solo".
func ExecutionRoleName(role protocol.ExecutionRole) string {
	if role == protocol.ExecutionRoleSolo {
		return "solo"
	}
	return string(role)
}

// ClusterRole names a cluster rank.
func ClusterRole(rank int) string {
	if rank == 0 {
		return "leader"
	}
	return "follower"
}

// ClusterPairs projects the coordinator's cluster listing onto one account.
func ClusterPairs(views []registry.NativePairView, accountID string, now time.Time) []ClusterPair {
	pairs := make([]ClusterPair, 0, len(views))
	for _, view := range views {
		if accountID == "" || view.AccountID != accountID {
			continue
		}
		pair := ClusterPair{ClusterID: view.ClusterID, PolicySHA256: view.PolicySHA256, ApprovalID: view.ApprovalID,
			Model: view.Model, State: string(view.State), Waiting: string(view.Waiting), ServingReady: view.ServingReady,
			Epoch: view.Epoch, PrepareBefore: optionalTime(view.PrepareBefore), ExpiresAt: optionalTime(view.ExpiresAt),
			ReformExpectedAt: optionalTime(view.ReformExpectedAt), Failures: view.Failures, Declines: view.Declines,
			RetryAt: optionalTime(view.RetryAt)}
		if remaining := view.ExpiresAt.Sub(now); !view.ExpiresAt.IsZero() && remaining > 0 {
			pair.RemainingLifetimeSeconds = int(remaining / time.Second)
		}
		for rank, member := range view.Members {
			pair.Members[rank] = ClusterPairMember{Rank: rank, Role: ClusterRole(rank), Attached: member.Attached,
				ProviderID: member.ProviderID, ChipName: member.ChipName, MemoryGB: member.MemoryGB}
		}
		pairs = append(pairs, pair)
	}
	return pairs
}

// AttachClusterPairs fills the pair fields of each cluster member's row from
// the coordinator's listing for the same account.
func AttachClusterPairs(fleet []Provider, views []registry.NativePairView, accountID string) {
	for _, view := range views {
		if accountID == "" || view.AccountID != accountID {
			continue
		}
		for rank, member := range view.Members {
			if !member.Attached {
				continue
			}
			for i := range fleet {
				if cluster := fleet[i].Cluster; cluster != nil && fleet[i].ID == member.ProviderID {
					cluster.PairState, cluster.Waiting = string(view.State), string(view.Waiting)
					cluster.ServingReady = view.ServingReady
					cluster.PeerProviderID = view.Members[1-rank].ProviderID
				}
			}
		}
	}
}

func optionalTime(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	return &t
}
