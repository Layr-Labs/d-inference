package registry_test

// The pair selector over time: when it offers two members to the reservation,
// when it waits, how it re-forms a pair after the fixed lifetime, after a lost
// member and after a refused preparation. The real selector loop, registry and
// relay run over in-memory provider writers on a synctest bubble's fake clock.
// Real provider sessions are covered in tests/api.

import (
	"context"
	"crypto/tls"
	"fmt"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/clustermember"
)

const (
	formationCluster  = "studio-pair"
	formationAccount  = "account-one"
	formationApproval = "fixture-formation-approval"
)

// formationFixture runs the production selector over two ranked members of
// one account. It reuses the relay fixture's frame reading and signing.
type formationFixture struct {
	*nativePairWireFixture
	writers  *memberFrameWriters
	policy   string
	accounts [2]string
	stop     context.CancelFunc
	next     int
	ids      []string
	// current guards the members the freshness loop keeps current; a rank is
	// nil there while a test wants its evidence to stay as it left it.
	currentMu sync.Mutex
	current   [2]*production.Provider
}

func newFormationFixture(t *testing.T) *formationFixture {
	t.Helper()
	writers := &memberFrameWriters{frames: make(map[string]chan protocol.NativePairMessage)}
	r := pairEnvironmentWith(t, production.Dependencies{Connections: writers})
	document := clustermember.CatalogDocument(t, clustermember.Approval(formationApproval, nativePairFixtureModel, "fixture-chip"))
	catalog, err := production.ParseNativeRuntimeCatalog(document)
	if err != nil {
		t.Fatal(err)
	}
	f := &formationFixture{writers: writers, policy: clustermember.PolicySHA256(t, document, formationApproval),
		accounts:              [2]string{formationAccount, formationAccount},
		nativePairWireFixture: &nativePairWireFixture{r: r, serials: [2]string{"serial-a", "serial-b"}}}
	f.c = production.NewNativePairCoordinator(r, catalog)
	if f.c == nil {
		t.Fatal("operator catalog did not construct the coordinator")
	}
	ctx, stop := context.WithCancel(context.Background())
	f.stop = stop
	go f.c.RunFormation(ctx)
	// Members stay within the pair gates' freshness windows as real ones do.
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				f.refresh()
			}
		}
	}()
	return f
}

// close ends the selector and every connection so the bubble can finish.
func (f *formationFixture) close() {
	f.stop()
	f.c.Close()
	for _, id := range f.ids {
		f.r.Disconnect(id)
	}
	synctest.Wait()
}

// attach registers a trusted member for rank with a fresh connection.
func (f *formationFixture) attach(t *testing.T, rank int, adjust func(*protocol.ClusterMembership)) {
	t.Helper()
	f.next++
	id := fmt.Sprintf("member-%d-%d", rank, f.next)
	membership := &protocol.ClusterMembership{ClusterID: formationCluster, Rank: rank, PolicySHA256: f.policy}
	if adjust != nil {
		adjust(membership)
	}
	nonce := fmt.Sprintf("%064x", f.next)
	f.nonces[rank], f.sent[rank] = nonce, 0
	f.p[rank] = pairMemberWith(t, f.r, nil, id, f.serials[rank], nonce, func(msg *protocol.RegisterMessage) {
		msg.ClusterMembership = membership
	})
	f.p[rank].Mu().Lock()
	f.p[rank].AccountID = f.accounts[rank]
	f.p[rank].Mu().Unlock()
	n, err := f.c.Attach(f.p[rank], nonce, production.NativePairDirectTLS(&tls.ConnectionState{HandshakeComplete: true}))
	if err != nil {
		t.Fatalf("attach rank%d: %v", rank, err)
	}
	f.n[rank], f.frames[rank] = n, f.writers.of(id)
	f.ids = append(f.ids, id)
	f.keepCurrent(rank, f.p[rank])
}

// keepCurrent selects which connection the freshness loop renews for rank.
func (f *formationFixture) keepCurrent(rank int, p *production.Provider) {
	f.currentMu.Lock()
	f.current[rank] = p
	f.currentMu.Unlock()
}

// leave drops rank's connection the way the provider read loop does.
func (f *formationFixture) leave(rank int) {
	f.keepCurrent(rank, nil)
	f.c.Detach(f.n[rank])
	f.r.Disconnect(f.p[rank].ID)
}

// refresh renews the heartbeat, challenge and release evidence of every
// connection kept current, as a live trusted member's own traffic would.
func (f *formationFixture) refresh() {
	f.currentMu.Lock()
	current := f.current
	f.currentMu.Unlock()
	for rank, p := range current {
		if p == nil {
			continue
		}
		serial := f.serials[rank]
		se := pairDeviceSEKey(serial)
		p.Mu().Lock()
		p.Attested, p.TrustLevel = true, production.TrustHardware
		p.LastHeartbeat, p.LastChallengeVerified = time.Now(), time.Now()
		p.Mu().Unlock()
		p.GrantApplicationEvidenceIfNotUntrusted(production.ApplicationEvidence{SEPublicKey: se, Serial: serial,
			ProcessPublicKey: p.PublicKey, BinaryHash: strings.Repeat("a", 64), MetallibHash: strings.Repeat("b", 64),
			Backend: p.Backend, Version: p.Version, PolicyGeneration: 7, VerifiedAt: time.Now()})
	}
}

// nextPrepares waits up to within for both ranks' prepare frames and adopts
// that session for the frames the fixture signs next.
func (f *formationFixture) nextPrepares(t *testing.T, within time.Duration) protocol.NativePairMessage {
	t.Helper()
	var first protocol.NativePairMessage
	for rank := range f.n {
		select {
		case m := <-f.frames[rank]:
			if m.Type != protocol.TypeNativePairPrepare {
				t.Fatalf("rank%d got %s, want a prepare", rank, m.Type)
			}
			f.starts[rank] = parsePrepareStart(t, m)
			if rank == 0 {
				first, f.epoch, f.gen = m, m.Epoch, m.Generation
			}
		case <-time.After(within):
			t.Fatalf("rank%d was not offered a pair within %s", rank, within)
		}
	}
	return first
}

func (f *formationFixture) view(t *testing.T) production.NativePairView {
	t.Helper()
	for _, v := range f.c.Pairs() {
		if v.ClusterID == formationCluster && v.AccountID == formationAccount {
			return v
		}
	}
	t.Fatalf("cluster is not listed: %+v", f.c.Pairs())
	return production.NativePairView{}
}

// quiet lets the selector run for d and fails if any member was sent a frame.
func (f *formationFixture) quiet(t *testing.T, d time.Duration, why string) {
	t.Helper()
	time.Sleep(d)
	synctest.Wait()
	for rank, frames := range f.frames {
		if frames == nil {
			continue
		}
		select {
		case m := <-frames:
			t.Fatalf("%s: rank%d was sent %s", why, rank, m.Type)
		default:
		}
	}
}

// commit answers both prepares so the owners are authorized.
func (f *formationFixture) commit(t *testing.T) {
	t.Helper()
	f.prepared(t, 0)
	f.prepared(t, 1)
	for rank := range f.n {
		f.read(t, rank, protocol.TypeNativePairOwnerStart)
	}
}

func TestPairSelectorWaitsForEligibilityThenForms(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newFormationFixture(t)
		defer f.close()
		f.attach(t, 0, nil)
		f.quiet(t, 30*time.Second, "one member alone")
		if v := f.view(t); v.State != production.NativePairStateWaiting || v.Waiting != production.NativePairWaitingPeer {
			t.Fatalf("lone leader is not waiting for its peer: %+v", v)
		}

		// The follower attaches before it is attested: listed, never offered.
		f.attach(t, 1, nil)
		f.keepCurrent(1, nil)
		f.p[1].SetAttested(false, production.TrustNone)
		f.quiet(t, time.Minute, "an unattested follower")
		if v := f.view(t); v.Waiting != production.NativePairWaitingIneligible || !v.Members[1].Attached {
			t.Fatalf("unattested follower is not reported as ineligible: %+v", v)
		}

		// Its evidence becomes current: the next selector period forms the pair.
		f.keepCurrent(1, f.p[1])
		f.refresh()
		prepare := f.readPrepares(t)
		v := f.view(t)
		if v.State != production.NativePairStatePreparing || v.Epoch != prepare.Epoch || v.ApprovalID != formationApproval ||
			v.Members[0].ProviderID != f.p[0].ID || v.Members[1].ProviderID != f.p[1].ID {
			t.Fatalf("formed pair is misreported: %+v", v)
		}
		f.commit(t)
		if v = f.view(t); v.State != production.NativePairStateActive {
			t.Fatalf("committed pair is not active: %+v", v)
		}
	})
}

func TestPairSelectorNeverGuessesMembership(t *testing.T) {
	// want is why every listed cluster must be waiting.
	want := map[string]production.NativePairWaiting{
		"different accounts":                  production.NativePairWaitingPeer,
		"different clusters":                  production.NativePairWaitingPeer,
		"different installed policies":        production.NativePairWaitingPeer,
		"follower registered no membership":   production.NativePairWaitingPeer,
		"policy the catalog does not approve": production.NativePairWaitingApproval,
		"revoked approval":                    production.NativePairWaitingApproval,
	}
	cases := map[string]func(f *formationFixture, t *testing.T){
		"different accounts": func(f *formationFixture, t *testing.T) {
			f.accounts[1] = "account-two"
			f.attach(t, 0, nil)
			f.attach(t, 1, nil)
		},
		"no account": func(f *formationFixture, t *testing.T) {
			f.accounts = [2]string{"", ""}
			f.attach(t, 0, nil)
			f.attach(t, 1, nil)
		},
		"different clusters": func(f *formationFixture, t *testing.T) {
			f.attach(t, 0, nil)
			f.attach(t, 1, func(m *protocol.ClusterMembership) { m.ClusterID = "other-pair" })
		},
		"different installed policies": func(f *formationFixture, t *testing.T) {
			f.attach(t, 0, nil)
			f.attach(t, 1, func(m *protocol.ClusterMembership) { m.PolicySHA256 = fmt.Sprintf("%064x", 9) })
		},
		"policy the catalog does not approve": func(f *formationFixture, t *testing.T) {
			unapproved := func(m *protocol.ClusterMembership) { m.PolicySHA256 = fmt.Sprintf("%064x", 9) }
			f.attach(t, 0, unapproved)
			f.attach(t, 1, unapproved)
		},
		"revoked approval": func(f *formationFixture, t *testing.T) {
			f.c.RevokeApproval(formationApproval)
			f.attach(t, 0, nil)
			f.attach(t, 1, nil)
		},
		"follower registered no membership": func(f *formationFixture, t *testing.T) {
			f.attach(t, 0, nil)
			f.next++
			nonce := fmt.Sprintf("%064x", f.next)
			f.p[1] = pairMember(t, f.r, nil, "plain-member", f.serials[1], nonce)
			f.p[1].Mu().Lock()
			f.p[1].AccountID = formationAccount
			f.p[1].Mu().Unlock()
			n, err := f.c.Attach(f.p[1], nonce, production.NativePairDirectTLS(&tls.ConnectionState{HandshakeComplete: true}))
			if err != nil {
				t.Fatal(err)
			}
			f.n[1], f.frames[1] = n, f.writers.of("plain-member")
			f.ids = append(f.ids, "plain-member")
			f.keepCurrent(1, f.p[1])
		},
	}
	for name, arrange := range cases {
		t.Run(name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				f := newFormationFixture(t)
				defer f.close()
				arrange(f, t)
				f.quiet(t, 2*time.Minute, name)
				listed := f.c.Pairs()
				if reason, listsClusters := want[name]; listsClusters == (len(listed) == 0) {
					t.Fatalf("%s: listed %+v, want waiting on %q", name, listed, reason)
				}
				for _, v := range listed {
					if v.State != production.NativePairStateWaiting || v.Waiting != want[name] {
						t.Fatalf("%s: cluster is %s/%q, want waiting/%q: %+v", name, v.State, v.Waiting, want[name], v)
					}
				}
			})
		})
	}
}

// A pair lives for one fixed lifetime. When it ends and both owners report
// cleanup, the selector forms the next session by itself.
func TestPairSelectorReformsAfterTheFixedLifetime(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newFormationFixture(t)
		defer f.close()
		f.attach(t, 0, nil)
		f.attach(t, 1, nil)
		first := f.readPrepares(t)
		f.commit(t)
		expires := time.Unix(0, first.ExpiresAtUnixNano)
		if lifetime := time.Until(expires); lifetime < 299*time.Second || lifetime > 300*time.Second {
			t.Fatalf("session lifetime is %s, want the fixed 300 s", lifetime)
		}
		starts := f.starts

		// Nothing is offered while the pair is active.
		f.quiet(t, time.Until(expires)-time.Second, "an active pair")

		// Expiry closes admission; both members are told and report cleanup.
		for rank := range f.n {
			f.read(t, rank, protocol.TypeNativePairCancel)
		}
		if v := f.view(t); v.State != production.NativePairStateWaiting || v.Waiting != production.NativePairWaitingHeld {
			t.Fatalf("expired pair is not reported as holding its devices pending cleanup: %+v", v)
		}
		for rank := range f.n {
			if err := f.c.Handle(f.n[rank], f.sign(t, rank, protocol.TypeNativePairOwnerReleased, releaseReceipt(starts[rank]))); err != nil {
				t.Fatalf("release receipt rank%d: %v", rank, err)
			}
		}

		// Both devices are free: the same two connections are paired again.
		second := f.readPrepares(t)
		if second.Epoch == first.Epoch || second.Generation <= first.Generation {
			t.Fatal("the next session reused the expired one")
		}
		f.commit(t)
		if v := f.view(t); v.State != production.NativePairStateActive || v.Failures != 0 {
			t.Fatalf("re-formed pair is not active: %+v", v)
		}
	})
}

// A member lost after commit leaves both devices held until its owner must
// have retired; only then is the surviving connection paired with the
// machine's new connection.
func TestPairSelectorReformsAfterALostMemberOnlyOnceTheHoldIsReleased(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newFormationFixture(t)
		defer f.close()
		f.attach(t, 0, nil)
		f.attach(t, 1, nil)
		first := f.readPrepares(t)
		f.commit(t)
		expires := time.Unix(0, first.ExpiresAtUnixNano)
		leaderStart := f.starts[0]

		f.leave(1)
		f.read(t, 0, protocol.TypeNativePairCancel)
		if err := f.c.Handle(f.n[0], f.sign(t, 0, protocol.TypeNativePairOwnerReleased, releaseReceipt(leaderStart))); err != nil {
			t.Fatalf("leader release receipt: %v", err)
		}
		// The follower's machine reconnects at once.
		f.attach(t, 1, nil)
		f.quiet(t, time.Until(expires.Add(ownerMayStillRun)), "a device whose departed owner may still be running")
		if v := f.view(t); v.Waiting != production.NativePairWaitingHeld {
			t.Fatalf("held device is not reported: %+v", v)
		}

		sleepUntil(expires.Add(ownersMustHaveRetired))
		second := f.readPrepares(t)
		if second.Epoch == first.Epoch {
			t.Fatal("the next session reused the lost one")
		}
	})
}

// A member that never answers a prepare costs the peer one preparation window
// per attempt; the selector spaces attempts out instead of repeating them.
func TestPairSelectorBacksOffAfterRefusedPreparations(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newFormationFixture(t)
		defer f.close()
		f.attach(t, 0, nil)
		f.attach(t, 1, nil)
		began := time.Now()
		var offered []time.Duration
		for attempt := 0; attempt < 4; attempt++ {
			f.nextPrepares(t, 2*time.Minute)
			offered = append(offered, time.Since(began))
			if attempt == 3 {
				break
			}
			// Neither member answers: the 30 s preparation window lapses.
			for rank := range f.n {
				select {
				case m := <-f.frames[rank]:
					if m.Type != protocol.TypeNativePairCancel {
						t.Fatalf("rank%d got %s while its preparation lapsed", rank, m.Type)
					}
				case <-time.After(40 * time.Second):
					t.Fatal("lapsed preparation was not cancelled")
				}
			}
		}
		for attempt := 1; attempt < len(offered); attempt++ {
			gap := offered[attempt] - offered[attempt-1]
			retry := time.Duration(1<<attempt) * time.Second // 2 s, 4 s, 8 s after the 30 s window
			if gap < 30*time.Second+retry || gap > 30*time.Second+retry+2*time.Second {
				t.Fatalf("attempt %d followed the previous one after %s, want about %s", attempt+1, gap, 30*time.Second+retry)
			}
		}
		if v := f.view(t); v.Failures != 3 {
			t.Fatalf("refused preparations are not counted: %+v", v)
		}
	})
}
