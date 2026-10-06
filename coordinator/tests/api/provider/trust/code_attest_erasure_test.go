package trust_test

import (
	"context"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/api/provider/trust"
	codeidentity "github.com/eigeninference/d-inference/coordinator/internal/provider/identity"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestCodeAttestForgetErasedKeysClearsOnlyUnsharedRuntimeIdentity(t *testing.T) {
	logger := quietLogger()
	srv := newTrustFixture(t, production.Dependencies{Registry: registry.New(logger), Store: memory.NewMemory(store.Config{}), Logger: logger}, production.Config{})
	th := srv.codeAttestThrottle
	generation := th.PublicationGeneration()
	loops := make(map[string]uint64)
	resumes := make(map[string]<-chan struct{})
	for _, key := range []string{"erased", "shared-live"} {
		th.RecordAttestedForProcess(generation, key, "1", "raw-token", "node", "binary")
		th.RecordChallengeForIdentity(generation, key, "push", "raw-token", "node")
		resumes[key] = th.RecordResumeChallenge(generation, "resume-"+key, key, "node", key, "raw-token")
		loops[key] = th.BeginLoop(key)
		if !th.tryReservePush(context.Background(), key, "raw-token", false, loops[key]) {
			t.Fatal("reserve fixture push")
		}
		if !th.ClearPushBudget(context.Background(), key) {
			t.Fatal("clear fixture budget")
		}
	}
	srv.ForgetErasedKeys([]string{"erased"})
	if _, ok := th.ProofForIdentity("erased", "1", "raw-token", "node", "binary"); ok {
		t.Fatal("erased raw APNs proof remains in memory")
	}
	if th.MatchChallengeForIdentity("erased", "push", "raw-token", "node") {
		t.Fatal("erased push challenge remains answerable")
	}
	if th.MatchResumeChallenge("resume-erased", "erased", "node", "erased", "raw-token") {
		t.Fatal("erased resume remains answerable")
	}
	select {
	case <-resumes["erased"]:
	default:
		t.Fatal("erasure did not cancel resume fallback")
	}
	if th.LoopCurrent("erased", loops["erased"]) || th.BudgetStatus("erased", "raw-token").Present {
		t.Fatal("erased loop or push budget remains")
	}
	if !th.ClearPushBudget(context.Background(), "erased") {
		t.Fatal("old budget-clear history remains")
	}
	if _, ok := th.ProofForIdentity("shared-live", "1", "raw-token", "node", "binary"); !ok {
		t.Fatal("another owner's proof removed")
	}
	if !th.MatchChallengeForIdentity("shared-live", "push", "raw-token", "node") || !th.MatchResumeChallenge("resume-shared-live", "shared-live", "node", "shared-live", "raw-token") {
		t.Fatal("another owner's challenge removed")
	}
	select {
	case <-resumes["shared-live"]:
		t.Fatal("another owner's resume canceled")
	default:
	}
	if !th.LoopCurrent("shared-live", loops["shared-live"]) || !th.BudgetStatus("shared-live", "raw-token").Present {
		t.Fatal("another owner's push bookkeeping removed")
	}
	th.ClearResumeChallenges("shared-live")
}

func TestCodeAttestErasureFencesOldPublicationsAndAllowsFreshProof(t *testing.T) {
	th := newThrottleFixture()
	old := th.PublicationGeneration() // captured before validation / durable read
	th.Forget([]string{"erased"})
	if th.RecordAttestedForProcess(old, "erased", "1", "old-token", "old-node", "binary") {
		t.Fatal("in-flight reply restored erased proof")
	}
	if th.RecordChallengeForIdentity(old, "erased", "old-nonce", "old-token", "old-node") {
		t.Fatal("in-flight push restored erased challenge")
	}
	if th.RecordResumeChallenge(old, "old-resume", "provider", "old-node", "erased", "old-token") != nil {
		t.Fatal("stale reuse restored erased resume challenge")
	}
	rows := []store.CodeAttestation{
		{SEPubKey: "erased", Version: "1", APNsToken: "old-token", NodePublicKey: "old-node", BinaryHash: "binary", AttestedAt: th.Now()},
		{SEPubKey: "live", Version: "1", APNsToken: "live-token", NodePublicKey: "live-node", BinaryHash: "binary", AttestedAt: th.Now()},
	}
	if n := th.Seed(old, rows); n != 1 {
		t.Fatalf("old snapshot seeded %d rows, want only unaffected live key", n)
	}
	th.SeedPushBudgets(old, []store.CodeAttestPushBudget{
		{SEPubKey: "erased", TokenHash: codeidentity.CodeAttestTokenHash("old-token"), NextPushAt: th.Now().Add(time.Hour)},
		{SEPubKey: "live", TokenHash: codeidentity.CodeAttestTokenHash("live-token"), NextPushAt: th.Now().Add(time.Hour)},
	})
	if _, ok := th.ProofForIdentity("erased", "1", "old-token", "old-node", "binary"); ok {
		t.Fatal("stale seed restored erased proof")
	}
	if th.BudgetStatus("erased", "old-token").Present || !th.BudgetStatus("live", "live-token").Present {
		t.Fatal("seed erasure fence affected the wrong keys")
	}
	fresh := th.PublicationGeneration()
	if !th.RecordChallengeForIdentity(fresh, "erased", "fresh-nonce", "new-token", "new-node") || !th.ConsumeChallengeForIdentity("erased", "fresh-nonce", "new-token", "new-node") {
		t.Fatal("new owner's fresh challenge cannot complete")
	}
	if !th.RecordAttestedForProcess(fresh, "erased", "2", "new-token", "new-node", "binary") {
		t.Fatal("new owner's fresh proof was refused")
	}
	if _, ok := th.ProofForIdentity("erased", "2", "new-token", "new-node", "binary"); !ok {
		t.Fatal("new owner's proof not retained")
	}
	if th.RecordAttestedForProcess(old, "erased", "1", "old-token", "old-node", "binary") {
		t.Fatal("late reply overwrote the fresh owner's proof")
	}
}

// Pause a real store read after it captures rows, not the cache under test.
type codeAttestSeedBarrier struct {
	*memory.MemoryStore
	loaded  chan struct{}
	release chan struct{}
}

func (s *codeAttestSeedBarrier) ListCodeAttestations(ctx context.Context) ([]store.CodeAttestation, error) {
	rows, err := s.MemoryStore.ListCodeAttestations(ctx)
	close(s.loaded)
	select {
	case <-s.release:
		return rows, err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func TestCodeAttestStartupReadCannotReseedForgottenProof(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	st := &codeAttestSeedBarrier{MemoryStore: memory.NewMemory(store.Config{}), loaded: make(chan struct{}), release: make(chan struct{})}
	for _, key := range []string{"erased", "live"} {
		if err := st.UpsertCodeAttestation(ctx, store.CodeAttestation{SEPubKey: key, Version: "1", APNsToken: "token", NodePublicKey: "node", BinaryHash: "binary", AttestedAt: time.Now()}); err != nil {
			t.Fatal(err)
		}
	}
	logger := quietLogger()
	srv := newTrustFixture(t, production.Dependencies{Registry: registry.New(logger), Store: st, Logger: logger}, production.Config{})
	done := make(chan struct{})
	go func() { defer close(done); srv.SeedCodeAttestCache(ctx) }()
	select {
	case <-st.loaded:
	case <-ctx.Done():
		t.Fatal("store read did not start")
	}
	if err := st.DeleteCodeAttestation(ctx, "erased"); err != nil {
		t.Fatal(err)
	}
	srv.ForgetErasedKeys([]string{"erased"})
	close(st.release)
	select {
	case <-done:
	case <-ctx.Done():
		t.Fatal("seed did not finish")
	}
	if _, ok := srv.codeAttestThrottle.ProofForIdentity("erased", "1", "token", "node", "binary"); ok {
		t.Fatal("startup read restored token after ForgetErasedKeys")
	}
	if _, ok := srv.codeAttestThrottle.ProofForIdentity("live", "1", "token", "node", "binary"); !ok {
		t.Fatal("concurrent erasure discarded unrelated persisted proof")
	}
}

func TestCodeAttestInFlightPushReplyCannotRestoreErasedProof(t *testing.T) {
	logger := quietLogger()
	srv := newTrustFixture(t, production.Dependencies{Registry: registry.New(logger), Store: memory.NewMemory(store.Config{}), Logger: logger}, production.Config{})
	public, private, signer, seKey := providerKeyMaterial(t)
	provider := newCodeAttestProvider(public, seKey)
	erase := true
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, public, nonce string) error {
		if erase {
			srv.ForgetErasedKeys([]string{seKey})
		}
		return completeRoundTrip(t, srv, provider, provider.ID, private, signer, public, nonce)
	}})
	if !srv.sendCodeIdentityChallenge(context.Background(), provider.ID, provider) {
		t.Fatal("APNs did not accept push")
	}
	if provider.GetCodeAttested() {
		t.Fatal("reply to erased challenge granted code trust")
	}
	if _, ok := srv.codeAttestThrottle.ProofForIdentity(seKey, provider.Version, provider.APNsDeviceToken, public, ""); ok {
		t.Fatal("late APNs reply restored raw token")
	}
	erase = false
	if !srv.sendCodeIdentityChallenge(context.Background(), provider.ID, provider) || !provider.GetCodeAttested() {
		t.Fatal("new owner's fresh challenge could not grant proof")
	}
}

type codeAttestBudgetClearBarrier struct {
	*memory.MemoryStore
	loaded  chan struct{}
	release chan struct{}
}

func (s *codeAttestBudgetClearBarrier) ClearCodeAttestPushFloor(ctx context.Context, key string, now time.Time, cooldown time.Duration) (time.Time, bool, error) {
	at, cleared, err := s.MemoryStore.ClearCodeAttestPushFloor(ctx, key, now, cooldown)
	close(s.loaded)
	select {
	case <-s.release:
		return at, cleared, err
	case <-ctx.Done():
		return time.Time{}, false, ctx.Err()
	}
}

func TestCodeAttestInFlightBudgetClearDoesNotRecreateErasedBookkeeping(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	st := &codeAttestBudgetClearBarrier{MemoryStore: memory.NewMemory(store.Config{}), loaded: make(chan struct{}), release: make(chan struct{})}
	th := newThrottleFixture()
	th.Store = st
	done := make(chan bool, 1)
	go func() { done <- th.ClearPushBudget(ctx, "erased") }()
	select {
	case <-st.loaded:
	case <-ctx.Done():
		t.Fatal("clear did not reach store")
	}
	// Forget must complete while unrelated store/transport work is blocked.
	th.Forget([]string{"erased"})
	close(st.release)
	select {
	case accepted := <-done:
		if accepted {
			t.Fatal("late clear recreated erased local bookkeeping")
		}
	case <-ctx.Done():
		t.Fatal("clear did not finish")
	}
}
