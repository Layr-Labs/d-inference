package registry_test

// Routing a request to a verified pair: which requests may reach it, when its
// leader is a candidate, what binds an attempt to the pair it was reserved on,
// and what happens to that attempt when the pair ends. The production
// selector, relay, scheduler and handoff run over in-memory provider writers
// on a synctest bubble's fake clock. Real sessions are covered in tests/api.

import (
	"errors"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// pairRoutingFixture is a formed pair of one account's members with the
// operator's routing opt-in under the test's control.
type pairRoutingFixture struct {
	*formationFixture
	expires time.Time
}

func newPairRoutingFixture(t *testing.T, routing bool, configure ...func(*production.Dependencies)) *pairRoutingFixture {
	t.Helper()
	f := &pairRoutingFixture{formationFixture: newFormationFixture(t, configure...)}
	if routing {
		f.r.EnableClusterPairRouting()
	}
	// The leader benchmarks 500 tok/s prefill and 50 tok/s decode, so a
	// request's lifetime budget is easy to state in the tests below.
	f.register = func(msg *protocol.RegisterMessage) { msg.PrefillTPS, msg.DecodeTPS = 500, 50 }
	f.attach(t, 0, nil)
	f.attach(t, 1, nil)
	f.expires = time.Unix(0, f.readPrepares(t).ExpiresAtUnixNano)
	f.commit(t)
	return f
}

// relayKeys completes the public key exchange both members run after commit.
func (f *pairRoutingFixture) relayKeys(t *testing.T) {
	t.Helper()
	for rank := range f.n {
		key := make([]byte, 32)
		key[0] = byte(rank + 1)
		hello := append(append([]byte("DBNH\x01"), f.starts[rank]...), key...)
		if err := f.c.Handle(f.n[rank], f.sign(t, rank, protocol.TypeNativePairHello, hello)); err != nil {
			t.Fatalf("hello rank%d: %v", rank, err)
		}
	}
	for rank := range f.n {
		f.read(t, rank, protocol.TypeNativePairBinding)
	}
	for rank := range f.n {
		confirmation := make([]byte, 32)
		confirmation[0] = byte(rank + 7)
		if err := f.c.Handle(f.n[rank], f.sign(t, rank, protocol.TypeNativePairConfirmation, confirmation)); err != nil {
			t.Fatalf("confirmation rank%d: %v", rank, err)
		}
	}
	for rank := range f.n {
		f.read(t, rank, protocol.TypeNativePairPeerConfirmation)
	}
}

// report applies a member heartbeat with the given slots, as its own backend
// would publish them.
func (f *pairRoutingFixture) report(rank int, status string, slots ...protocol.BackendSlotCapacity) {
	f.r.Heartbeat(f.p[rank].ID, &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: status,
		BackendCapacity: &protocol.BackendCapacity{TotalMemoryGB: 64, Slots: append([]protocol.BackendSlotCapacity{}, slots...)}})
}

func pairSlot() protocol.BackendSlotCapacity {
	return protocol.BackendSlotCapacity{Model: nativePairFixtureModel, State: "idle"}
}

// serve brings the committed pair to serving: keys relayed and the leader
// reporting the pair model loaded.
func (f *pairRoutingFixture) serve(t *testing.T) {
	t.Helper()
	f.relayKeys(t)
	f.report(0, "idle", pairSlot())
}

// solo registers an ordinary trusted provider of the pair's model with the
// model loaded, owned by account (empty for none).
func (f *pairRoutingFixture) solo(t *testing.T, id, account string) *production.Provider {
	t.Helper()
	p := makeSchedulerProvider(t, f.r, id, nativePairFixtureModel, 50)
	p.Mu().Lock()
	p.AccountID = account
	p.BackendCapacity.Slots[0].State = "idle"
	p.Mu().Unlock()
	f.ids = append(f.ids, id)
	return p
}

// ownerRequest is a request authenticated as account and scoped to that
// account's own machines.
func ownerRequest(id, account string) *production.PendingRequest {
	return &production.PendingRequest{RequestID: id, Model: nativePairFixtureModel,
		OwnerAccountID: account, SelfRouteOnly: true, EstimatedPromptTokens: 100, RequestedMaxTokens: 100,
		ChunkCh: make(chan production.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
}

func (f *pairRoutingFixture) reserve(pr *production.PendingRequest) (*production.Provider, production.RoutingDecision) {
	return f.r.ReserveProviderEx(nativePairFixtureModel, pr)
}

func gateTally(d production.RoutingDecision, reason production.GateReason) int {
	return int(d.GateRejections[reason])
}

// requireActive fails unless the cluster still has its session after the pair
// gates were re-validated.
func (f *pairRoutingFixture) requireActive(t *testing.T, why string) {
	t.Helper()
	synctest.Wait()
	if v := f.view(t); v.State != production.NativePairStateActive {
		t.Fatalf("%s: pair is %s/%q, want active", why, v.State, v.Waiting)
	}
}

func TestOwnerRequestIsRoutedToItsServingPairLeader(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newPairRoutingFixture(t, true)
		defer f.close()

		// Committed, but the members have not exchanged keys: a capacity wait.
		selected, decision := f.reserve(ownerRequest("before-keys", formationAccount))
		if selected != nil || decision.CapacityRejections != 1 || gateTally(decision, production.GatePairNotReady) != 1 {
			t.Fatalf("pair without relayed keys: selected=%v capacity=%d gates=%v", selected != nil, decision.CapacityRejections, decision.GateRejections)
		}
		// Keys relayed, model not loaded on the leader yet: still a wait.
		f.relayKeys(t)
		selected, decision = f.reserve(ownerRequest("before-load", formationAccount))
		if selected != nil || decision.CapacityRejections != 1 || gateTally(decision, production.GatePairNotReady) != 1 {
			t.Fatalf("pair without a loaded leader slot: selected=%v capacity=%d gates=%v", selected != nil, decision.CapacityRejections, decision.GateRejections)
		}

		// The leader reports the pair model loaded: it is the candidate.
		f.report(0, "idle", pairSlot())
		pending := ownerRequest("served", formationAccount)
		selected, decision = f.reserve(pending)
		if selected != f.p[0] || decision.CandidateCount != 1 {
			t.Fatalf("serving pair did not select its leader: selected=%v decision=%+v", selected, decision)
		}
		if f.p[0].PendingCount() != 1 || f.p[1].PendingCount() != 0 {
			t.Fatal("the request was not reserved on the leader alone")
		}
		// The handoff authorization admits the leader for this attempt.
		if err := f.p[0].NewInferenceHandoff(pending).Authorize(); err != nil {
			t.Fatalf("handoff to the serving pair leader refused: %v", err)
		}

		// Serving does not end the pair: its own request and its own loaded
		// slot survive every re-validation of the pair gates.
		f.report(0, "serving", protocol.BackendSlotCapacity{Model: nativePairFixtureModel, State: "running", NumRunning: 1})
		time.Sleep(90 * time.Second)
		f.requireActive(t, "a leader serving its pair's request")
		if f.p[0].PendingCount() != 1 {
			t.Fatal("the pair's request was dropped while the pair was active")
		}
	})
}

func TestPairIsRoutableOnlyForItsOwnAccount(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newPairRoutingFixture(t, true)
		defer f.close()
		f.serve(t)

		// Another account scoping a request to its own machines owns neither
		// member: no candidate, no capacity signal, no error.
		selected, decision := f.reserve(ownerRequest("stranger", "account-two"))
		if selected != nil || decision.CandidateCount != 0 || decision.CapacityRejections != 0 {
			t.Fatalf("another account's self-route reached the pair: selected=%v decision=%+v", selected != nil, decision)
		}
		// An ordinary request carries no owner scope: the pair is not capacity
		// for it either.
		public := ownerRequest("public", "")
		public.SelfRouteOnly = false
		selected, decision = f.reserve(public)
		if selected != nil || decision.CandidateCount != 0 || decision.CapacityRejections != 0 ||
			gateTally(decision, production.GateMemberOnly) != 2 {
			t.Fatalf("a public request saw the pair: selected=%v decision=%+v", selected != nil, decision)
		}
		// With a solo provider for the same model the public request is served
		// there, exactly as if the pair did not exist.
		solo := f.solo(t, "solo-public", "")
		public = ownerRequest("public-with-solo", "")
		public.SelfRouteOnly = false
		if selected, _ = f.reserve(public); selected != solo {
			t.Fatalf("public request was not served by the solo provider: %v", selected)
		}
		// A foreign prefer-owner request falls back to the public fleet too.
		foreign := ownerRequest("foreign-prefer", "account-two")
		foreign.SelfRouteOnly, foreign.PreferOwner = false, true
		if selected, _ = f.reserve(foreign); selected != solo {
			t.Fatalf("another account's prefer-owner request was not served by the solo provider: %v", selected)
		}
		// The owner's prefer-owner request takes its own pair over the fleet.
		owned := ownerRequest("owner-prefer", formationAccount)
		owned.SelfRouteOnly, owned.PreferOwner = false, true
		if selected, _ = f.reserve(owned); selected != f.p[0] {
			t.Fatalf("the owner's prefer-owner request did not use its pair: %v", selected)
		}
	})
}

// The handoff re-checks the account restriction: an attempt reserved on a pair
// is not handed over once its request no longer belongs to the pair's account.
func TestPairHandoffIsRefusedForAnotherAccountOrAnotherModel(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newPairRoutingFixture(t, true)
		defer f.close()
		f.serve(t)
		pending := ownerRequest("prefer", formationAccount)
		pending.SelfRouteOnly, pending.PreferOwner = false, true
		if selected, _ := f.reserve(pending); selected != f.p[0] {
			t.Fatal("fixture request was not reserved on the pair")
		}
		handoff := f.p[0].NewInferenceHandoff(pending)
		if err := handoff.Authorize(); err != nil {
			t.Fatalf("owner handoff refused: %v", err)
		}
		pending.OwnerAccountID = "account-two"
		if err := handoff.Authorize(); !errors.Is(err, production.ErrProviderServingUnauthorized) {
			t.Fatalf("handoff for another account: %v, want unauthorized", err)
		}
		pending.OwnerAccountID = formationAccount
		// The catalog stops approving the pair's model: nothing more is handed over.
		f.r.SetModelCatalog([]production.CatalogEntry{{ID: "another-model"}})
		if err := handoff.Authorize(); !errors.Is(err, production.ErrProviderServingUnauthorized) {
			t.Fatalf("handoff for a model the catalog dropped: %v, want unauthorized", err)
		}
	})
}

// A request is admitted only when the pair will outlive the coordinator's
// estimate of it. Shorter remaining lifetime is a capacity wait for the next
// pair, never a mid-request cut the coordinator could have avoided.
func TestPairLifetimeAdmission(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newPairRoutingFixture(t, true)
		defer f.close()
		f.serve(t)
		// 5 000 prompt tokens at 500 tok/s plus 1 000 output tokens at 50 tok/s.
		request := func(id string) *production.PendingRequest {
			pr := ownerRequest(id, formationAccount)
			pr.EstimatedPromptTokens, pr.RequestedMaxTokens = 5_000, 1_000
			return pr
		}
		long := func(id string) *production.PendingRequest {
			pr := ownerRequest(id, formationAccount)
			pr.RequestedMaxTokens = 1_000_000
			return pr
		}
		admitted := func(pr *production.PendingRequest) bool {
			selected, decision := f.reserve(pr)
			if selected != nil {
				f.p[0].RemovePending(pr.RequestID)
				return true
			}
			if decision.CapacityRejections != 1 || gateTally(decision, production.GatePairLifetime) != 1 {
				t.Fatalf("%s refused for something other than lifetime: %+v", pr.RequestID, decision)
			}
			return false
		}
		if !admitted(request("fresh")) || !admitted(long("fresh-long")) {
			t.Fatal("a fresh pair refused a request")
		}
		// Past half the lifetime a request that cannot finish inside any pair
		// waits for the next one; an ordinary request is still admitted.
		sleepUntil(f.expires.Add(-140 * time.Second))
		if admitted(long("late-long")) {
			t.Fatal("a request longer than the cap was admitted in the second half of the lifetime")
		}
		if !admitted(request("mid")) {
			t.Fatal("a 30 s request was refused with 140 s of lifetime left")
		}
		sleepUntil(f.expires.Add(-45 * time.Second))
		if !admitted(request("enough")) {
			t.Fatal("a request was refused although the pair outlives its estimate")
		}
		sleepUntil(f.expires.Add(-20 * time.Second))
		if admitted(request("too-late")) {
			t.Fatal("a request was admitted to a pair that ends before its estimate")
		}
	})
}

// When the pair ends, the requests reserved on it fail over at once: each gets
// the health-neutral restart terminal, the leader is told to stop, and the
// leader's connection is left clean for the next pair.
func TestPairEndFailsItsRequestsWithTheRestartTerminal(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newPairRoutingFixture(t, true)
		defer f.close()
		f.serve(t)
		pending := ownerRequest("in-flight", formationAccount)
		if selected, _ := f.reserve(pending); selected != f.p[0] {
			t.Fatal("fixture request was not reserved on the pair")
		}
		leaderStart := f.starts[0]

		f.leave(1)
		synctest.Wait()
		select {
		case terminal := <-pending.ErrorCh:
			if terminal.CoordinatorCause != protocol.CoordinatorCauseProviderRestart || terminal.StatusCode != 502 ||
				terminal.ErrorReason != protocol.InferenceErrorReasonProviderRestart || terminal.RequestID != "in-flight" {
				t.Fatalf("pair end delivered %+v, want the health-neutral restart terminal", terminal)
			}
		default:
			t.Fatal("the request reserved on the ended pair was left waiting")
		}
		if f.p[0].PendingCount() != 0 {
			t.Fatal("the ended pair's request still occupies the leader")
		}
		// The leader is still connected: its read loop may be delivering a
		// chunk or a completion for this request right now, so those channels
		// must still accept a send.
		func() {
			defer func() {
				if recover() != nil {
					t.Fatal("pair end closed a channel the connected leader may still be writing")
				}
			}()
			pending.ChunkCh <- production.ProviderChunk{Data: "late"}
			pending.CompleteCh <- protocol.UsageInfo{}
		}()
		if err := f.p[0].NewInferenceHandoff(pending).Authorize(); !errors.Is(err, production.ErrProviderServingUnauthorized) {
			t.Fatalf("handoff after the pair ended: %v, want unauthorized", err)
		}
		kinds := map[string]bool{}
		for len(f.frames[0]) > 0 {
			kinds[(<-f.frames[0]).Type] = true
		}
		if !kinds[protocol.TypeNativePairCancel] || !kinds[protocol.TypeCancel] {
			t.Fatalf("leader was sent %v, want the pair cancel and the request cancel", kinds)
		}

		// The owner's next request waits for the next pair instead of failing.
		f.report(0, "draining")
		selected, decision := f.reserve(ownerRequest("during-rotation", formationAccount))
		if selected != nil || decision.CapacityRejections != 1 {
			t.Fatalf("a rotating pair is not a capacity wait: selected=%v decision=%+v", selected != nil, decision)
		}

		// Nothing of the old request blocks the next session.
		if err := f.c.Handle(f.n[0], f.sign(t, 0, protocol.TypeNativePairOwnerReleased, releaseReceipt(leaderStart))); err != nil {
			t.Fatalf("leader release receipt: %v", err)
		}
		f.attach(t, 1, nil)
		sleepUntil(f.expires.Add(ownersMustHaveRetired))
		f.readPrepares(t)
	})
}

func TestPairExpiryFailsItsRequests(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newPairRoutingFixture(t, true)
		defer f.close()
		f.serve(t)
		pending := ownerRequest("until-expiry", formationAccount)
		if selected, _ := f.reserve(pending); selected != f.p[0] {
			t.Fatal("fixture request was not reserved on the pair")
		}
		sleepUntil(f.expires.Add(time.Second))
		synctest.Wait()
		select {
		case terminal := <-pending.ErrorCh:
			if terminal.CoordinatorCause != protocol.CoordinatorCauseProviderRestart {
				t.Fatalf("expiry delivered %+v, want the restart terminal", terminal)
			}
		default:
			t.Fatal("the request outlived its pair's fixed lifetime")
		}
	})
}

// An active pair still ends when a member holds anything that is not the
// pair's own work.
func TestActivePairEndsOnForeignWork(t *testing.T) {
	cases := map[string]func(f *pairRoutingFixture){
		"follower reports a loaded slot": func(f *pairRoutingFixture) { f.report(1, "idle", pairSlot()) },
		"leader reports a slot that is not loaded": func(f *pairRoutingFixture) {
			f.report(0, "idle", protocol.BackendSlotCapacity{Model: nativePairFixtureModel, State: "reloading"})
		},
		"leader holds a request that was not reserved on the pair": func(f *pairRoutingFixture) {
			f.p[0].AddPending(ownerRequest("foreign", formationAccount))
		},
	}
	for name, arrange := range cases {
		t.Run(name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				f := newPairRoutingFixture(t, true)
				defer f.close()
				f.serve(t)
				arrange(f)
				time.Sleep(90 * time.Second)
				synctest.Wait()
				if v := f.view(t); v.State == production.NativePairStateActive {
					t.Fatalf("%s: the pair stayed active", name)
				}
			})
		})
	}
}

// Without the operator's routing opt-in nothing changes: a formed, serving
// pair is never a candidate for anyone, and a leader that reports a loaded
// slot ends its pair exactly as before.
func TestPairRoutingIsOffUnlessEnabled(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newPairRoutingFixture(t, false)
		defer f.close()
		f.relayKeys(t)

		selected, decision := f.reserve(ownerRequest("owner", formationAccount))
		if selected != nil || decision.CandidateCount != 0 || decision.CapacityRejections != 0 ||
			gateTally(decision, production.GateMemberOnly) != 2 {
			t.Fatalf("routing off: selected=%v decision=%+v, want both members dropped as member_only", selected != nil, decision)
		}
		if online, serves := f.r.OwnedProviderSummary(formationAccount, nativePairFixtureModel, production.RequestTraits{}, false); online != 2 || serves != 0 {
			t.Fatalf("routing off: owner summary online=%d serves=%d, want 2 and 0", online, serves)
		}

		f.report(0, "idle", pairSlot())
		selected, decision = f.reserve(ownerRequest("owner-loaded", formationAccount))
		if selected != nil || decision.CapacityRejections != 0 {
			t.Fatalf("routing off: a loaded leader was offered: selected=%v decision=%+v", selected != nil, decision)
		}
		time.Sleep(90 * time.Second)
		synctest.Wait()
		if v := f.view(t); v.State == production.NativePairStateActive {
			t.Fatal("routing off: a leader holding a loaded slot kept its pair")
		}
	})
}

func TestOwnedProviderSummaryCountsThePairOnce(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newPairRoutingFixture(t, true)
		defer f.close()
		summary := func(account string) [2]int {
			online, serves := f.r.OwnedProviderSummary(account, nativePairFixtureModel, production.RequestTraits{}, false)
			return [2]int{online, serves}
		}
		// Both machines are online; the pair serves the model once, and
		// already while it is still becoming ready, so a request waits for it.
		if got := summary(formationAccount); got != [2]int{2, 1} {
			t.Fatalf("owner summary = %v, want two machines online and one serving unit", got)
		}
		f.serve(t)
		if got := summary(formationAccount); got != [2]int{2, 1} {
			t.Fatalf("owner summary of a serving pair = %v, want [2 1]", got)
		}
		if got := summary("account-two"); got != [2]int{0, 0} {
			t.Fatalf("another account's summary = %v, want nothing", got)
		}
		if _, serves := f.r.OwnedProviderSummary(formationAccount, "another-model", production.RequestTraits{}, false); serves != 0 {
			t.Fatal("the pair was counted for a model it does not serve")
		}
	})
}

// When the pair ends because the leader's own connection is lost, the
// disconnect decides what its requests are told: an abrupt loss is a provider
// fault, not the health-neutral end of a pair.
func TestLeaderDisconnectKeepsItsOwnTerminalCause(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newPairRoutingFixture(t, true)
		defer f.close()
		f.serve(t)
		pending := ownerRequest("leader-lost", formationAccount)
		if selected, _ := f.reserve(pending); selected != f.p[0] {
			t.Fatal("fixture request was not reserved on the pair")
		}
		// The read loop detaches the member from pair control as soon as its
		// socket ends and removes it from the registry only later, after its
		// terminal work is joined. Nothing may fail the request in between.
		f.keepCurrent(0, nil)
		f.c.Detach(f.n[0])
		synctest.Wait()
		select {
		case terminal := <-pending.ErrorCh:
			t.Fatalf("pair control failed a lost leader's request as %q before its disconnect", terminal.CoordinatorCause)
		default:
		}
		f.r.Disconnect(f.p[0].ID)
		synctest.Wait()
		select {
		case terminal := <-pending.ErrorCh:
			if terminal.CoordinatorCause != protocol.CoordinatorCauseProviderDisconnected {
				t.Fatalf("leader loss delivered cause %q, want the disconnect fault", terminal.CoordinatorCause)
			}
		default:
			t.Fatal("the request on a lost leader was left waiting")
		}
	})
}

// How requests fared on a machine governs routing to it, not whether its pair
// exists: a fault cooldown neither keeps two members from pairing nor ends
// their pair, and the leader is simply not selected while it lasts.
func TestRequestFaultsGovernRoutingNotThePair(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := &pairRoutingFixture{formationFixture: newFormationFixture(t)}
		defer f.close()
		f.r.EnableClusterPairRouting()
		f.attach(t, 0, nil)
		f.attach(t, 1, nil)
		for rank := range f.p {
			if !f.r.RecordDispatchLoadFailure(f.p[rank].ID, nativePairFixtureModel) {
				t.Fatalf("fixture load-failure cooldown did not start for rank%d", rank)
			}
		}
		f.expires = time.Unix(0, f.readPrepares(t).ExpiresAtUnixNano)
		f.commit(t)
		f.serve(t)

		selected, decision := f.reserve(ownerRequest("cooled", formationAccount))
		// Both members carry the cooldown, and it is the first gate either meets.
		if selected != nil || gateTally(decision, production.GateDispatchLoadCooldown) != 2 {
			t.Fatalf("a cooled leader: selected=%v gates=%v, want it skipped for the cooldown", selected != nil, decision.GateRejections)
		}
		time.Sleep(90 * time.Second)
		f.requireActive(t, "a leader in a request-fault cooldown")
		f.r.ClearDispatchLoadCooldown(f.p[0].ID, nativePairFixtureModel)
		if selected, _ = f.reserve(ownerRequest("recovered", formationAccount)); selected != f.p[0] {
			t.Fatal("the leader was not selected once its cooldown cleared")
		}
	})
}

// A leader whose slot for the pair model is not loaded is a capacity wait,
// whatever state the slot reports.
func TestPairLeaderWithoutALoadedSlotIsACapacityWait(t *testing.T) {
	for _, state := range []string{"crashed", "reloading", "idle_shutdown"} {
		t.Run(state, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				f := newPairRoutingFixture(t, true)
				defer f.close()
				f.serve(t)
				f.report(0, "idle", protocol.BackendSlotCapacity{Model: nativePairFixtureModel, State: state})
				selected, decision := f.reserve(ownerRequest("not-loaded", formationAccount))
				if selected != nil || decision.CapacityRejections != 1 || gateTally(decision, production.GatePairNotReady) != 1 {
					t.Fatalf("slot %s: selected=%v capacity=%d gates=%v", state, selected != nil, decision.CapacityRejections, decision.GateRejections)
				}
			})
		})
	}
}

// A quarantined pair is something its owner waits for only while a member can
// still release it. Once its owners must have retired and a connected member
// has still not reported cleanup, no time ends that hold, so the owner's
// preflight stops reporting the model as served.
func TestStuckQuarantineIsNotReportedAsServing(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newPairRoutingFixture(t, true)
		defer f.close()
		f.serve(t)
		serves := func() int {
			_, n := f.r.OwnedProviderSummary(formationAccount, nativePairFixtureModel, production.RequestTraits{}, false)
			return n
		}
		// The follower's session is cancelled; neither member ever reports cleanup.
		if err := f.c.Handle(f.n[1], f.sign(t, 1, protocol.TypeNativePairCancel, []byte("DBNC\x01"))); err != nil {
			t.Fatal(err)
		}
		synctest.Wait()
		if serves() != 1 {
			t.Fatal("a rotating pair is not reported as served while its members may still release it")
		}
		sleepUntil(f.expires.Add(ownersMustHaveRetired))
		synctest.Wait()
		if serves() != 0 {
			t.Fatal("a quarantine no time can end is still reported as serving the model")
		}
	})
}

// The owner preflight for a forced tool choice asks the pair through its
// leader, like routing does.
func TestOwnerToolConstraintPreflightSeesThePair(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := &pairRoutingFixture{formationFixture: newFormationFixture(t)}
		defer f.close()
		f.r.EnableClusterPairRouting()
		f.register = func(msg *protocol.RegisterMessage) {
			msg.ToolConstraintProtocol, msg.ToolConstraintModels = 1, []string{nativePairFixtureModel}
		}
		f.attach(t, 0, nil)
		f.attach(t, 1, nil)
		f.readPrepares(t)
		f.commit(t)
		if !f.r.HasToolConstraintProviderForRouting(nativePairFixtureModel, formationAccount, true, false) {
			t.Fatal("the owner's forced tool choice finds no provider although its pair advertises enforcement")
		}
		if f.r.HasToolConstraintProviderForRouting(nativePairFixtureModel, "account-two", true, false) ||
			f.r.HasToolConstraintProviderForModel(nativePairFixtureModel) {
			t.Fatal("the pair answered a tool-constraint preflight that was not its owner's")
		}
	})
}
