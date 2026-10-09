package api_test

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/clustermember"
)

// The provider accepts no native-pair frame before its cluster_member_accepted
// acknowledgement and drops the connection if one arrives first. With the
// selector armed and an eligible leader already waiting, a follower that is
// eligible the instant it registers must still read the acknowledgement before
// its prepare. The follower's evidence is fabricated from the moment its
// registration reaches the registry, which is before the coordinator attaches
// it to pair control, so the selector could otherwise act in that window.
// Whether a given session hits the window is a race; many sessions are run.
func TestMemberAcknowledgementPrecedesEveryNativePairFrame(t *testing.T) {
	d := newPairDeployment(t, withCatalog)
	const sessions = 200
	prepared := 0
	for session := 0; session < sessions; session++ {
		// A new cluster each time: a cluster whose preparation was abandoned
		// is retried only after a backoff.
		cluster := fmt.Sprintf("pair-%d", session)
		leader, leaderProvider := d.member(t, "account-one", cluster, fmt.Sprintf("serial-leader-%d", session), 0)
		d.makeEligible(t, leader, leaderProvider)
		follower := clustermember.New(t, clustermember.Options{
			ServerURL: d.server.URL, HTTPClient: d.server.Client(), AuthToken: "token-account-one",
			Serial: fmt.Sprintf("serial-follower-%d", session), ChipName: pairChip, Model: pairModel,
			Membership: &protocol.ClusterMembership{ClusterID: cluster, Rank: 1, PolicySHA256: d.policy},
		})
		// Keep the follower's fabricated evidence and capacity in place from
		// the moment the registry holds its connection: registration is still
		// running then, and refuses or overwrites parts of it for a while.
		stop, stopped := make(chan struct{}), make(chan struct{})
		go func() {
			defer close(stopped)
			for {
				select {
				case <-stop:
					return
				default:
				}
				for _, id := range d.fixture.Registry.ProviderIDs() {
					p := d.fixture.Registry.GetProvider(id)
					if p == nil {
						continue
					}
					p.Mu().Lock()
					mine := p.PublicKey == follower.ProcessKey
					if mine {
						p.BackendCapacity = &protocol.BackendCapacity{TotalMemoryGB: 64, Slots: []protocol.BackendSlotCapacity{}}
						p.LastHeartbeat = time.Now()
					}
					p.Mu().Unlock()
					if mine {
						clustermember.TryGrantPairTrust(p, follower)
					}
				}
			}
		}()
		follower.Connect(t, d.ctx)

		acknowledged := false
		for {
			frame, ok := follower.Next(d.ctx)
			if !ok {
				t.Fatalf("session %d: follower socket ended (acknowledged=%v)", session, acknowledged)
			}
			if frame.Type == protocol.TypeClusterMemberAccepted {
				acknowledged = true
				continue
			}
			if strings.HasPrefix(frame.Type, "native_pair_") {
				if !acknowledged {
					t.Fatalf("session %d: follower was sent %s before its acknowledgement", session, frame.Type)
				}
				if frame.Type == protocol.TypeNativePairPrepare {
					prepared++
				}
				break
			}
		}
		close(stop)
		<-stopped
		_ = follower.Conn.CloseNow()
		_ = leader.Conn.CloseNow()
	}
	if prepared != sessions {
		t.Fatalf("only %d of %d followers were offered a pair; the ordering was not exercised", prepared, sessions)
	}
}
