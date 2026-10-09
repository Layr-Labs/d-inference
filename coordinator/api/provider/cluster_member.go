package provider

import (
	"context"
	"encoding/json"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// acknowledgeClusterMember queues cluster_member_accepted for a connection the
// registry holds in the control-only member role; a solo connection is sent
// nothing. The acknowledgement confirms protocol support and this connection's
// nonce only. A provider that sees none before its negotiation deadline ends
// its control loop for good, so a failed enqueue is returned for the caller to
// close the socket and let the provider negotiate again on a new connection.
func (s *Owner) acknowledgeClusterMember(ctx context.Context, provider *registry.Provider) error {
	acceptance, isMember := provider.ClusterMemberAcceptance()
	if !isMember {
		return nil
	}
	data, err := json.Marshal(acceptance)
	if err != nil {
		return err
	}
	return provider.EnqueueText(ctx, data)
}
