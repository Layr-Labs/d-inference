package registry

import (
	"errors"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"strings"
	"testing"
	"time"
)

func TestClusterMemberNeverSoloRoutesEvenWithAdvertisedLoadedOrColdModels(t *testing.T) {
	r, members, request := pairTestRegistry(t)
	for _, p := range members {
		p.mu.Lock()
		p.executionRole = protocol.ExecutionRoleClusterMember
		p.mu.Unlock()
	}
	for _, cold := range []bool{false, true} {
		for _, p := range members {
			p.mu.Lock()
			if cold {
				p.BackendCapacity.Slots = nil
				p.WarmModels = nil
				p.CurrentModel = ""
			}
			p.mu.Unlock()
		}
		if findRoutableProvider(r, pairTestModel) != nil {
			t.Fatal("member entered solo route")
		}
		if count, _, _ := r.QuickCapacityCheck(pairTestModel, 1, 1, RequestTraits{}); count != 0 {
			t.Fatal("member counted as capacity")
		}
		r.mu.RLock()
		members[0].mu.Lock()
		ordinary, _ := r.providerRoutingGateReasonLockedEx(members[0], pairTestModel, RequestTraits{}, true, time.Now(), false, false)
		_, reason := r.warmPoolCandidateReasonLocked(members[0], pairTestModel, time.Now())
		warm := r.providerHasWarmModelLocked(members[0], pairTestModel, time.Now())
		members[0].mu.Unlock()
		_, loadable := r.modelLoadCandidatePendingLocked(members[1], pairTestModel, time.Now())
		r.mu.RUnlock()
		if ordinary || warm || loadable || reason != warmColdMemberOnly {
			t.Fatal("role bypass via private/warm/load reader", reason)
		}
	}
	for _, call := range []func() error{
		func() error { return r.SendLoadModel(members[0].ID, pairTestModel) },
		func() error { return r.SendPrefetchModel(members[0].ID, pairTestModel, 1) },
		func() error {
			return r.SendDesiredModels(members[0].ID, []protocol.DesiredModelEntry{{DesiredBuild: pairTestModel}})
		},
	} {
		if !errors.Is(call(), ErrVerifiedPairBusy) {
			t.Fatal("member received solo command")
		}
	}
	h, _ := pairTestActive(t, r, members, request)
	if _, err := r.ValidateVerifiedPair(h); err != nil {
		t.Fatal("member strict pair selection failed", err)
	}
	// Exact same strict trust flags remain necessary in the pair-only context.
	members[0].SetAttested(false, TrustNone)
	if _, err := r.ValidateVerifiedPair(h); err == nil {
		t.Fatal("member role upgraded trust")
	}
}

func TestClusterMemberRegistrationRoleImmutableAcrossModelsAndReconnect(t *testing.T) {
	r := New(testLogger())
	p := r.Register("member", nil, &protocol.RegisterMessage{ExecutionRole: protocol.ExecutionRoleClusterMember,
		MemberRegistrationNonce: strings.Repeat("a", 64), ClusterModels: []protocol.ModelInfo{{ID: pairTestModel}}, Models: []protocol.ModelInfo{}})
	if p.executionRole != protocol.ExecutionRoleClusterMember || len(p.Models) != 1 {
		t.Fatal("cluster inventory not installed")
	}
	duplicate := r.Register("member", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: pairTestModel}}})
	if duplicate != p || duplicate.executionRole != protocol.ExecutionRoleClusterMember {
		t.Fatal("duplicate registration changed role")
	}
	r.Disconnect("member")
	q := r.Register("member-new", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: pairTestModel}}})
	if q == p || q.executionRole != protocol.ExecutionRoleSolo {
		t.Fatal("role inherited across connections")
	}
}

func TestClusterMemberReconnectCannotReusePairGrant(t *testing.T) {
	r, members, request := pairTestRegistry(t)
	for _, p := range members {
		p.mu.Lock()
		p.executionRole = protocol.ExecutionRoleClusterMember
		p.mu.Unlock()
	}
	h, m := pairTestActive(t, r, members, request)
	r.Disconnect(members[0].ID)
	pairTestDone(t, h)
	replacement := pairTestMember(t, r, "new-member-connection", "serial-a")
	replacement.mu.Lock()
	replacement.executionRole = protocol.ExecutionRoleClusterMember
	replacement.mu.Unlock()
	if _, err := r.ValidateVerifiedPair(h); err == nil {
		t.Fatal("old active grant survived disconnect")
	}
	if err := r.ObserveVerifiedPairOwnerReleased(h, replacement, m.TranscriptSHA256); !errors.Is(err, ErrVerifiedPairStale) {
		t.Fatal("replacement released prior owner")
	}
	if _, _, err := r.ReserveVerifiedPair([2]*Provider{replacement, members[1]}, request); err == nil {
		t.Fatal("uncertain active device reused on reconnect")
	}
}
