package api_test

// A customer request reaching a cluster pair through the composed server: the
// owner's request is handed to the pair's leader over its real provider
// session and answered there; nobody else's request reaches the pair; and a
// request in flight when the pair rotates is served by the next pair. The
// members are fake (clustermember) and their trust evidence is fabricated.

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/clustermember"
)

// servingPair is a deployment whose two members of account-one formed a pair
// and whose leader reports the pair model loaded.
type servingPair struct {
	*pairDeployment
	leader, follower                 *clustermember.Member
	leaderProvider, followerProvider *registry.Provider
	prepares                         [2]protocol.NativePairMessage
	starts                           [2][]byte
}

func newServingPair(t *testing.T) *servingPair {
	t.Helper()
	s := &servingPair{pairDeployment: newPairDeployment(t, withCatalog)}
	s.leader, s.leaderProvider = s.member(t, "account-one", "studio-pair", "serial-leader", 0)
	s.follower, s.followerProvider = s.member(t, "account-one", "studio-pair", "serial-follower", 1)
	s.makeEligible(t, s.leader, s.leaderProvider)
	s.makeEligible(t, s.follower, s.followerProvider)
	s.establish(t)
	return s
}

// establish plays the members through one session and has the leader report
// the pair model loaded.
func (s *servingPair) establish(t *testing.T) {
	t.Helper()
	s.prepares, s.starts = clustermember.EstablishPair(t, s.ctx, [2]*clustermember.Member{s.leader, s.follower})
	s.leader.HeartbeatServing(t, s.ctx)
	s.waitForPair(t, "studio-pair", "serving", func(v registry.NativePairView) bool {
		return v.State == registry.NativePairStateActive && v.ServingReady
	})
}

func (d *pairDeployment) apiKey(t *testing.T, account string) string {
	t.Helper()
	key, _, err := d.fixture.Store.CreateAPIKey(account, store.APIKeyCreate{Name: "cluster-pair-test"})
	if err != nil {
		t.Fatal(err)
	}
	return key
}

type chatResult struct {
	status int
	body   string
}

// chat posts one streaming chat completion for the pair model. route is the
// X-Darkbloom-Route value, empty for an ordinary request.
func (d *pairDeployment) chat(t *testing.T, key, route string) <-chan chatResult {
	t.Helper()
	body := `{"model":"` + pairModel + `","messages":[{"role":"user","content":"hello pair"}],"stream":true,"max_tokens":32}`
	req, err := http.NewRequestWithContext(d.ctx, http.MethodPost, d.server.URL+"/v1/chat/completions", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+key)
	if route != "" {
		req.Header.Set("X-Darkbloom-Route", route)
	}
	out := make(chan chatResult, 1)
	go func() {
		resp, err := d.server.Client().Do(req)
		if err != nil {
			out <- chatResult{body: err.Error()}
			return
		}
		defer resp.Body.Close()
		data, _ := io.ReadAll(resp.Body)
		out <- chatResult{status: resp.StatusCode, body: string(data)}
	}()
	return out
}

func awaitChat(t *testing.T, result <-chan chatResult) chatResult {
	t.Helper()
	select {
	case r := <-result:
		return r
	case <-time.After(20 * time.Second):
		t.Fatal("the request did not finish")
		return chatResult{}
	}
}

// requireNoInferenceRequest reads m for a short while and fails if it is sent
// an inference request. The read deadline ends m's socket.
func requireNoInferenceRequest(t *testing.T, m *clustermember.Member, why string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	for {
		frame, ok := m.Next(ctx)
		if !ok {
			return
		}
		if frame.Type == protocol.TypeInferenceRequest {
			t.Fatalf("%s: member was sent an inference request", why)
		}
	}
}

func TestOwnerRequestIsServedByItsClusterPairLeader(t *testing.T) {
	s := newServingPair(t)
	result := s.chat(t, s.apiKey(t, "account-one"), "self")

	// The ordinary request frame arrives on the leader's own session,
	// encrypted to the key the leader registered.
	request, body := s.leader.ReadInferenceRequest(t, s.ctx)
	if !strings.Contains(string(body), "hello pair") {
		t.Fatalf("leader received a body other than the customer's request: %s", body)
	}
	s.leader.AnswerInference(t, s.ctx, request, "answered by the pair", protocol.UsageInfo{PromptTokens: 3, CompletionTokens: 4})

	got := awaitChat(t, result)
	if got.status != http.StatusOK || !strings.Contains(got.body, "answered by the pair") {
		t.Fatalf("owner request: status %d body %s", got.status, got.body)
	}
	if v := s.pair(t, "studio-pair"); v.State != registry.NativePairStateActive {
		t.Fatalf("serving a request ended the pair: %+v", v)
	}
	requireNoInferenceRequest(t, s.follower, "the follower is never a routing target")
}

// When a pair ends with a request in flight, that request fails at once with
// the ordinary provider-disconnected error and the leader is told to stop; it
// is not left to time out. A request that arrives while the cluster is
// re-forming waits, and the next pair serves it on the same leader connection:
// ending a pair costs the leader nothing.
func TestPairEndFailsTheRequestInFlightAndTheNextPairServesTheNextRequest(t *testing.T) {
	s := newServingPair(t)
	key := s.apiKey(t, "account-one")
	cut := s.chat(t, key, "self")
	first, _ := s.leader.ReadInferenceRequest(t, s.ctx)

	// The leader ends the session before producing anything.
	members := [2]*clustermember.Member{s.leader, s.follower}
	ended := s.prepares[0].Epoch
	s.leader.SendNativePair(t, s.ctx, protocol.TypeNativePairCancel, s.prepares[0], []byte("DBNC\x01"))
	if got := awaitChat(t, cut); got.status != http.StatusBadGateway || !strings.Contains(got.body, "provider disconnected") {
		t.Fatalf("request in flight when its pair ended: status %d body %s", got.status, got.body)
	}
	// The leader is told both things, in either order: its session is
	// cancelled, and the request it was handed is cancelled.
	for sessionCancelled, requestCancelled := false, false; !sessionCancelled || !requestCancelled; {
		frame, ok := s.leader.Next(s.ctx)
		if !ok {
			t.Fatalf("leader socket ended: session cancelled=%v request cancelled=%v", sessionCancelled, requestCancelled)
		}
		switch frame.Type {
		case protocol.TypeNativePairCancel:
			sessionCancelled = true
		case protocol.TypeCancel:
			var cancel protocol.CancelMessage
			if err := json.Unmarshal(frame.Data, &cancel); err != nil || cancel.RequestID != first.RequestID {
				t.Fatalf("leader was told to cancel %q, want the ended pair's request", cancel.RequestID)
			}
			requestCancelled = true
		}
	}
	s.follower.ReadNativePair(t, s.ctx, protocol.TypeNativePairCancel)
	reforming := s.waitForPair(t, "studio-pair", "re-forming", func(v registry.NativePairView) bool {
		return v.State == registry.NativePairStateReforming
	})
	if reforming.ServingReady || reforming.ReformExpectedAt.IsZero() {
		t.Fatalf("re-forming cluster is misreported: %+v", reforming)
	}

	// A request that arrives during the rotation is a capacity wait.
	waiting := s.chat(t, key, "self")
	deadline := time.Now().Add(5 * time.Second)
	for s.fixture.Registry.Queue().TotalSize() != 1 {
		if time.Now().After(deadline) {
			t.Fatal("a request for a re-forming pair was not queued")
		}
		time.Sleep(5 * time.Millisecond)
	}

	// Both members clean up and report it, as at the end of every fixed
	// lifetime; the coordinator forms the next session by itself.
	for rank, m := range members {
		m.Heartbeat(t, s.ctx)
		m.SendNativePair(t, s.ctx, protocol.TypeNativePairOwnerReleased, s.prepares[rank], clustermember.ReleaseReceipt(s.starts[rank]))
	}
	s.establish(t)
	if s.prepares[0].Epoch == ended || s.pair(t, "studio-pair").Epoch != s.prepares[0].Epoch {
		t.Fatal("the next session is not a new one, or not the one the cluster is listed with")
	}
	second, _ := s.leader.ReadInferenceRequest(t, s.ctx)
	if second.RequestID == first.RequestID {
		t.Fatal("the next pair was sent the ended pair's attempt")
	}
	s.leader.AnswerInference(t, s.ctx, second, "answered after rotation", protocol.UsageInfo{PromptTokens: 3, CompletionTokens: 4})
	if got := awaitChat(t, waiting); got.status != http.StatusOK || !strings.Contains(got.body, "answered after rotation") {
		t.Fatalf("request that waited for the next pair: status %d body %s", got.status, got.body)
	}
}

// outcome is what a client can tell apart: the status and the error code.
func (r chatResult) outcome() string {
	var body struct {
		Error struct {
			Code string `json:"code"`
			Type string `json:"type"`
		} `json:"error"`
	}
	_ = json.Unmarshal([]byte(r.body), &body)
	return http.StatusText(r.status) + "/" + body.Error.Type + "/" + body.Error.Code
}

// A pair serves only the account that owns both members. For everyone else it
// is not an error and not capacity: each of another account's requests gets
// exactly the answer it got before the pair existed, and none reaches a member.
func TestAnotherAccountsRequestsBehaveAsIfThePairWereAbsent(t *testing.T) {
	d := newPairDeployment(t, withCatalog)
	stranger := d.apiKey(t, "account-two")
	// An ordinary request and one scoped to the stranger's own machines. (A
	// prefer-owner request with no provider anywhere waits in the queue; the
	// registry tests cover it against a public provider.)
	routes := []string{"", "self"}
	before := map[string]string{}
	for _, route := range routes {
		before[route] = awaitChat(t, d.chat(t, stranger, route)).outcome()
	}

	s := &servingPair{pairDeployment: d}
	s.leader, s.leaderProvider = s.member(t, "account-one", "studio-pair", "serial-leader", 0)
	s.follower, s.followerProvider = s.member(t, "account-one", "studio-pair", "serial-follower", 1)
	s.makeEligible(t, s.leader, s.leaderProvider)
	s.makeEligible(t, s.follower, s.followerProvider)
	s.establish(t)

	for _, route := range routes {
		if after := awaitChat(t, d.chat(t, stranger, route)).outcome(); after != before[route] {
			t.Fatalf("another account's request (route %q) answered %s with a serving pair, %s without one", route, after, before[route])
		}
	}
	if before[""] == "OK//" {
		t.Fatal("fixture has a public provider for the pair model; the comparison proves nothing")
	}
	requireNoInferenceRequest(t, s.leader, "another account's request")
	requireNoInferenceRequest(t, s.follower, "another account's request")
}

// Without the operator's cluster pair configuration a pair formed through the
// in-process hook is never routed to: the owner's request is answered exactly
// as it is for members that have no pair at all.
func TestClusterPairRoutingIsOffWithoutConfiguration(t *testing.T) {
	d := newPairDeployment(t, func(cfg *api.ServerConfig, _ string) {
		catalog, err := registry.ParseNativeRuntimeCatalog(clustermember.CatalogDocument(t,
			clustermember.Approval(pairApproval, pairModel, pairChip)))
		if err != nil {
			t.Fatal(err)
		}
		cfg.NativePairCatalog = catalog
	})
	leader, leaderProvider := d.member(t, "account-one", "studio-pair", "serial-leader", 0)
	follower, followerProvider := d.member(t, "account-one", "studio-pair", "serial-follower", 1)
	d.makeEligible(t, leader, leaderProvider)
	d.makeEligible(t, follower, followerProvider)
	owner := d.apiKey(t, "account-one")
	unpaired := awaitChat(t, d.chat(t, owner, "self")).outcome()

	if _, err := d.fixture.Server.BeginNativePair([2]*registry.Provider{leaderProvider, followerProvider}, pairApproval, time.Minute); err != nil {
		t.Fatal(err)
	}
	clustermember.EstablishPair(t, d.ctx, [2]*clustermember.Member{leader, follower})
	if paired := awaitChat(t, d.chat(t, owner, "self")).outcome(); paired != unpaired || paired == "OK//" {
		t.Fatalf("owner request answered %s with a pair and %s without one; routing is not off", paired, unpaired)
	}
	requireNoInferenceRequest(t, leader, "routing without configuration")
}
