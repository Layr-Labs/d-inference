package api_test

// Pair formation through the composed server and real provider sessions: the
// operator's catalog file becomes the approval catalog, the selector offers
// two same-account members to the existing reserve → prepared → commit
// lifecycle, and a member's loss ends the pair. Members are fake (they speak
// the real protocol and sign with a generated key) and their trust evidence is
// fabricated through the registry's public setters; these tests establish
// control flow, not hardware trust.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/clustermember"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

const (
	pairModel    = "cluster-pair-fixture-model"
	pairApproval = "fixture-pair-approval"
	pairChip     = "Apple M3 Max"
)

// pairDeployment is a coordinator with the cluster pair opt-in, served over
// real TLS, with one provider token per account.
type pairDeployment struct {
	fixture *testkit.Fixture
	server  *httptest.Server
	policy  string
	ctx     context.Context
}

func newPairDeployment(t *testing.T, configure func(cfg *api.ServerConfig, catalogPath string)) *pairDeployment {
	t.Helper()
	approval := clustermember.Approval(pairApproval, pairModel, pairChip)
	document := clustermember.CatalogDocument(t, approval)
	var cfg api.ServerConfig
	configure(&cfg, clustermember.CatalogFile(t, approval))
	d := &pairDeployment{fixture: testkit.New(t, cfg), policy: clustermember.PolicySHA256(t, document, pairApproval)}
	d.fixture.Registry.SetModelCatalog([]registry.CatalogEntry{{ID: pairModel}})
	d.fixture.Registry.SetReleasePolicyGeneration(clustermember.ReleasePolicyGeneration, true, nil)
	for _, account := range []string{"account-one", "account-two"} {
		sum := sha256.Sum256([]byte("token-" + account))
		if err := d.fixture.Store.CreateProviderToken(&store.ProviderToken{
			TokenHash: hex.EncodeToString(sum[:]), AccountID: account, Active: true}); err != nil {
			t.Fatal(err)
		}
	}
	d.server = httptest.NewTLSServer(d.fixture.Server.Handler())
	t.Cleanup(d.server.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	d.ctx = ctx
	// The production startup call; a no-op unless the operator opted in.
	d.fixture.Server.StartClusterPairFormation(ctx)
	return d
}

func withCatalog(cfg *api.ServerConfig, catalogPath string) {
	cfg.ClusterPairs.CatalogPath = catalogPath
}

// member connects one fake member, waits for its acknowledgement and returns
// it with the registry's connection for it.
func (d *pairDeployment) member(t *testing.T, account, cluster, serial string, rank int) (*clustermember.Member, *registry.Provider) {
	t.Helper()
	m := clustermember.Dial(t, d.ctx, clustermember.Options{
		ServerURL: d.server.URL, HTTPClient: d.server.Client(), AuthToken: "token-" + account,
		Serial: serial, ChipName: pairChip, Model: pairModel,
		Membership: &protocol.ClusterMembership{ClusterID: cluster, Rank: rank, PolicySHA256: d.policy},
	})
	frames := m.ReadUntil(t, d.ctx, protocol.TypeClusterMemberAccepted)
	var accepted protocol.ClusterMemberAcceptedMessage
	if err := json.Unmarshal(frames[len(frames)-1].Data, &accepted); err != nil {
		t.Fatal(err)
	}
	provider := d.fixture.Registry.GetProvider(accepted.ProviderID)
	if provider == nil {
		t.Fatal("acknowledged member is not registered")
	}
	return m, provider
}

// makeEligible gives a registered member the fabricated evidence and the
// first capacity heartbeat the pair gates require.
func (d *pairDeployment) makeEligible(t *testing.T, m *clustermember.Member, p *registry.Provider) {
	t.Helper()
	clustermember.GrantPairTrust(t, p, m)
	m.Heartbeat(t, d.ctx)
	deadline := time.Now().Add(5 * time.Second)
	for {
		p.Mu().Lock()
		reported := p.BackendCapacity != nil
		p.Mu().Unlock()
		if reported {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("member heartbeat was not applied")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (d *pairDeployment) pair(t *testing.T, cluster string) registry.NativePairView {
	t.Helper()
	for _, view := range d.fixture.Server.ClusterPairs() {
		if view.ClusterID == cluster {
			return view
		}
	}
	t.Fatalf("cluster %q is not listed: %+v", cluster, d.fixture.Server.ClusterPairs())
	return registry.NativePairView{}
}

func (d *pairDeployment) waitForPair(t *testing.T, cluster, what string, reached func(registry.NativePairView) bool) registry.NativePairView {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		view := d.pair(t, cluster)
		if reached(view) {
			return view
		}
		if time.Now().After(deadline) {
			t.Fatalf("cluster %q never reached %s: %+v", cluster, what, view)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// selectorPeriods is a little longer than one selector period: long enough
// for a running selector to have acted on members that were already eligible.
const selectorPeriods = 1500 * time.Millisecond

// requireNoNativePairFrame reads for selectorPeriods and fails on any
// native-pair frame. The read deadline ends the member's socket, so this is
// the last thing a test does with that member.
func requireNoNativePairFrame(t *testing.T, m *clustermember.Member, why string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), selectorPeriods)
	defer cancel()
	for {
		frame, ok := m.Next(ctx)
		if !ok {
			return
		}
		if strings.HasPrefix(frame.Type, "native_pair_") {
			t.Fatalf("%s: member received %s", why, frame.Type)
		}
	}
}

func TestClusterPairFormsForSameAccountMembersAndReachesActive(t *testing.T) {
	d := newPairDeployment(t, withCatalog)
	leader, leaderProvider := d.member(t, "account-one", "studio-pair", "serial-leader", 0)
	follower, followerProvider := d.member(t, "account-one", "studio-pair", "serial-follower", 1)

	// Registered and attached, but not yet attested: nothing may be offered.
	if view := d.pair(t, "studio-pair"); view.State != registry.NativePairStateWaiting ||
		!view.Members[0].Attached || !view.Members[1].Attached || view.AccountID != "account-one" {
		t.Fatalf("unattested members are not listed as a waiting cluster: %+v", view)
	}

	d.makeEligible(t, leader, leaderProvider)
	d.makeEligible(t, follower, followerProvider)

	// The selector reserves both devices and each member is sent the exact
	// policy it registered, with its own rank's start.
	members := [2]*clustermember.Member{leader, follower}
	var prepares [2]protocol.NativePairMessage
	var starts [2][]byte
	for rank, m := range members {
		prepares[rank] = m.ReadNativePair(t, d.ctx, protocol.TypeNativePairPrepare)
		policy, start := clustermember.PreparePayload(t, prepares[rank])
		if sum := sha256.Sum256(policy); hex.EncodeToString(sum[:]) != d.policy {
			t.Fatalf("rank %d was sent a policy other than the one it registered", rank)
		}
		starts[rank] = start
	}
	if prepares[0].Epoch != prepares[1].Epoch || string(starts[0]) == string(starts[1]) {
		t.Fatal("members were not prepared for one session with distinct ranked starts")
	}
	preparing := d.pair(t, "studio-pair")
	if preparing.State != registry.NativePairStatePreparing || preparing.ApprovalID != pairApproval ||
		preparing.Model != pairModel || preparing.Epoch != prepares[0].Epoch ||
		preparing.Members[0].ProviderID != leaderProvider.ID || preparing.Members[1].ProviderID != followerProvider.ID ||
		preparing.Members[0].SerialNumber != "serial-leader" {
		t.Fatalf("preparing pair is misreported: %+v", preparing)
	}

	// Both signed preparation receipts commit the owners; only then is a start sent.
	for rank, m := range members {
		m.SendNativePair(t, d.ctx, protocol.TypeNativePairPrepared, prepares[rank], starts[rank])
	}
	for rank, m := range members {
		start := m.ReadNativePair(t, d.ctx, protocol.TypeNativePairOwnerStart)
		if payload, _ := start.PayloadBytes(); string(payload) != string(starts[rank]) {
			t.Fatalf("rank %d owner start differs from its prepared start", rank)
		}
	}
	active := d.waitForPair(t, "studio-pair", "active", func(v registry.NativePairView) bool {
		return v.State == registry.NativePairStateActive
	})
	if lifetime := time.Until(active.ExpiresAt); lifetime <= 4*time.Minute || lifetime > 5*time.Minute {
		t.Fatalf("active pair lifetime is %s, want the fixed five-minute session", lifetime)
	}

	// The committed session relays the public key exchange between the members.
	var hellos [2][]byte
	for rank, m := range members {
		key := make([]byte, 32)
		key[0] = byte(rank + 1)
		hellos[rank] = append(append([]byte("DBNH\x01"), starts[rank]...), key...)
		m.SendNativePair(t, d.ctx, protocol.TypeNativePairHello, prepares[rank], hellos[rank])
	}
	binding := append(append([]byte("DBNB\x01"), hellos[0]...), hellos[1]...)
	for rank, m := range members {
		got := m.ReadNativePair(t, d.ctx, protocol.TypeNativePairBinding)
		if payload, _ := got.PayloadBytes(); string(payload) != string(binding) {
			t.Fatalf("rank %d binding is not the ordered pair of hellos", rank)
		}
	}
}

func TestClusterPairEndsWhenAMemberIsLostAndFormsAgainWhenItReturns(t *testing.T) {
	d := newPairDeployment(t, withCatalog)
	leader, leaderProvider := d.member(t, "account-one", "studio-pair", "serial-leader", 0)
	follower, followerProvider := d.member(t, "account-one", "studio-pair", "serial-follower", 1)
	d.makeEligible(t, leader, leaderProvider)
	d.makeEligible(t, follower, followerProvider)
	first := leader.ReadNativePair(t, d.ctx, protocol.TypeNativePairPrepare)
	follower.ReadNativePair(t, d.ctx, protocol.TypeNativePairPrepare)

	// The follower drops while both are still preparing: no owner was
	// authorized, so the hold is released at once and the leader is told.
	_ = follower.Conn.CloseNow()
	if cancelled := leader.ReadNativePair(t, d.ctx, protocol.TypeNativePairCancel); cancelled.Epoch != first.Epoch {
		t.Fatal("leader was told to cancel a session other than its own")
	}
	d.waitForPair(t, "studio-pair", "waiting for its follower", func(v registry.NativePairView) bool {
		return v.State == registry.NativePairStateWaiting && v.Waiting == registry.NativePairWaitingPeer &&
			v.Members[0].Attached && !v.Members[1].Attached
	})

	// The follower's machine reconnects: a new connection, a new session.
	returned, returnedProvider := d.member(t, "account-one", "studio-pair", "serial-follower", 1)
	d.makeEligible(t, returned, returnedProvider)
	leader.Heartbeat(t, d.ctx)
	second := leader.ReadNativePair(t, d.ctx, protocol.TypeNativePairPrepare)
	again := returned.ReadNativePair(t, d.ctx, protocol.TypeNativePairPrepare)
	if second.Epoch == first.Epoch || again.Epoch != second.Epoch {
		t.Fatal("the re-formed pair reused the lost session")
	}

	// After commit a lost member cannot free the devices: the pair ends, the
	// survivor is told, and the selector does not offer a held device again.
	_, leaderStart := clustermember.PreparePayload(t, second)
	_, followerStart := clustermember.PreparePayload(t, again)
	leader.SendNativePair(t, d.ctx, protocol.TypeNativePairPrepared, second, leaderStart)
	returned.SendNativePair(t, d.ctx, protocol.TypeNativePairPrepared, again, followerStart)
	leader.ReadNativePair(t, d.ctx, protocol.TypeNativePairOwnerStart)
	returned.ReadNativePair(t, d.ctx, protocol.TypeNativePairOwnerStart)
	_ = returned.Conn.CloseNow()
	leader.ReadNativePair(t, d.ctx, protocol.TypeNativePairCancel)

	third, thirdProvider := d.member(t, "account-one", "studio-pair", "serial-follower", 1)
	d.makeEligible(t, third, thirdProvider)
	leader.Heartbeat(t, d.ctx)
	held := d.waitForPair(t, "studio-pair", "re-forming once the ended pair's hold is released", func(v registry.NativePairView) bool {
		return v.State == registry.NativePairStateReforming && v.Waiting == registry.NativePairWaitingHeld
	})
	if held.ReformExpectedAt.IsZero() || held.ServingReady {
		t.Fatalf("re-forming cluster is misreported: %+v", held)
	}
	requireNoNativePairFrame(t, third, "a device still held by a committed pair was offered again")
}

func TestClusterPairNeverCrossesAccountsOrClusters(t *testing.T) {
	d := newPairDeployment(t, withCatalog)
	leader, leaderProvider := d.member(t, "account-one", "studio-pair", "serial-leader", 0)
	stranger, strangerProvider := d.member(t, "account-two", "studio-pair", "serial-stranger", 1)
	other, otherProvider := d.member(t, "account-one", "other-pair", "serial-other", 1)
	sameRank, sameRankProvider := d.member(t, "account-one", "studio-pair", "serial-same-rank", 0)
	for _, m := range []struct {
		member   *clustermember.Member
		provider *registry.Provider
	}{{leader, leaderProvider}, {stranger, strangerProvider}, {other, otherProvider}, {sameRank, sameRankProvider}} {
		d.makeEligible(t, m.member, m.provider)
	}
	requireNoNativePairFrame(t, leader, "a member was paired across accounts, clusters or with its own rank")
	listed := d.fixture.Server.ClusterPairs()
	if len(listed) != 3 {
		t.Fatalf("want three separate clusters listed, got %+v", listed)
	}
	for _, view := range listed {
		if view.State != registry.NativePairStateWaiting || view.Waiting != registry.NativePairWaitingPeer {
			t.Fatalf("an unpairable cluster is not waiting for a peer: %+v", view)
		}
	}
}

// With no cluster pair configuration the coordinator behaves as it did before
// the feature: a member is acknowledged and nothing else. Two fully eligible
// same-account members with matching registrations are never attached, listed
// or offered a pair, and a native-pair frame from one is refused.
func TestClusterPairsAreOffWithoutConfiguration(t *testing.T) {
	d := newPairDeployment(t, func(*api.ServerConfig, string) {})
	leader, leaderProvider := d.member(t, "account-one", "studio-pair", "serial-leader", 0)
	follower, followerProvider := d.member(t, "account-one", "studio-pair", "serial-follower", 1)
	d.makeEligible(t, leader, leaderProvider)
	d.makeEligible(t, follower, followerProvider)

	if listed := d.fixture.Server.ClusterPairs(); len(listed) != 0 {
		t.Fatalf("clusters listed without configuration: %+v", listed)
	}
	if _, err := d.fixture.Server.BeginNativePair([2]*registry.Provider{leaderProvider, followerProvider}, pairApproval, time.Minute); err == nil {
		t.Fatal("a pair was begun without configuration")
	}
	requireNoNativePairFrame(t, leader, "pair control ran without configuration")

	// A control frame stays refused: the connection is closed, as before, and
	// nothing native was sent to it first.
	follower.SendNativePair(t, d.ctx, protocol.TypeNativePairCancel,
		protocol.NativePairMessage{Epoch: strings.Repeat("2", 32), Generation: 1}, []byte("DBNC\x01"))
	for {
		frame, ok := follower.Next(d.ctx)
		if !ok {
			break
		}
		if strings.HasPrefix(frame.Type, "native_pair_") {
			t.Fatalf("pair control ran without configuration: member received %s", frame.Type)
		}
	}
	deadline := time.Now().Add(5 * time.Second)
	for d.fixture.Registry.GetProvider(followerProvider.ID) != nil {
		if time.Now().After(deadline) {
			t.Fatal("a native-pair frame did not end the unconfigured connection")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// A catalog handed to the server directly (the explicit in-process hook)
// enables pair control but not the selector: only the operator opt-in does.
func TestExplicitCatalogDoesNotStartTheSelector(t *testing.T) {
	var catalog *registry.NativeRuntimeCatalog
	d := newPairDeployment(t, func(cfg *api.ServerConfig, _ string) {
		parsed, err := registry.ParseNativeRuntimeCatalog(clustermember.CatalogDocument(t,
			clustermember.Approval(pairApproval, pairModel, pairChip)))
		if err != nil {
			t.Fatal(err)
		}
		catalog = parsed
		cfg.NativePairCatalog = parsed
	})
	if policy, _ := catalog.PolicySHA256(pairApproval); policy != d.policy {
		t.Fatal("fixture catalogs disagree on the policy commitment")
	}
	leader, leaderProvider := d.member(t, "account-one", "studio-pair", "serial-leader", 0)
	follower, followerProvider := d.member(t, "account-one", "studio-pair", "serial-follower", 1)
	d.makeEligible(t, leader, leaderProvider)
	d.makeEligible(t, follower, followerProvider)

	// A running selector would have reserved these eligible members by now,
	// and the explicit hook would then find them already in a session.
	time.Sleep(selectorPeriods)
	if _, err := d.fixture.Server.BeginNativePair([2]*registry.Provider{leaderProvider, followerProvider}, pairApproval, time.Minute); err != nil {
		t.Fatalf("explicit selection refused, or the selector ran without the operator opt-in: %v", err)
	}
	leader.ReadNativePair(t, d.ctx, protocol.TypeNativePairPrepare)
	follower.ReadNativePair(t, d.ctx, protocol.TypeNativePairPrepare)
}
