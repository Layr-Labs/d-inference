package trust_test

import (
	"context"
	"fmt"

	production "github.com/eigeninference/d-inference/coordinator/api/provider/trust"

	codeidentity "github.com/eigeninference/d-inference/coordinator/internal/provider/identity"

	identitystate "github.com/eigeninference/d-inference/coordinator/internal/provider/identity/state"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// The fixture retains caller tokens across rotations, not controller state.
type throttleFixture struct {
	*codeidentity.Throttle
	tokens     map[string]int
	resumeDone <-chan struct{}
}

func newThrottleFixture() *throttleFixture {
	return &throttleFixture{Throttle: codeidentity.NewThrottle(identitystate.NewPolicy(production.CodeAttestResponseTimeout, production.ChallengeResponseTimeout)), tokens: make(map[string]int)}
}

func (t *throttleFixture) reuseAttestation(seKey, version, token, nodeKey string) bool {
	return t.ReuseAttestationBasis(seKey, version, token, nodeKey) != ""
}

func (t *throttleFixture) tryReservePush(ctx context.Context, seKey, token string, alert bool, generation uint64) bool {
	release, ok := t.ReservePush(ctx, seKey, token, alert, generation)
	if release != nil {
		release()
	}
	return ok
}

func (t *throttleFixture) allowPush(seKey string, alert bool) bool {
	if seKey == "" {
		return true
	}
	budget := t.BudgetStatus(seKey, fmt.Sprint(t.tokens[seKey]))
	return t.AllowsPush(budget.LastPushAt, !budget.LastPushAt.IsZero(), t.Now(), alert)
}

func (t *throttleFixture) recordPush(seKey string) {
	if seKey == "" {
		return
	}
	generation := t.BeginLoop(seKey)
	if !t.tryReservePush(context.Background(), seKey, fmt.Sprint(t.tokens[seKey]), false, generation) {
		panic("fixture push reservation denied")
	}
	t.EndLoop(seKey, generation)
}

func (t *throttleFixture) ClearPushBudget(ctx context.Context, seKey string) bool {
	cleared := t.Throttle.ClearPushBudget(ctx, seKey)
	if cleared {
		t.tokens[seKey]++
	}
	return cleared
}

func (t *throttleFixture) recordAttested(seKey, version, token string) {
	t.Seed(t.PublicationGeneration(), []store.CodeAttestation{{SEPubKey: seKey, Version: version, APNsToken: token, AttestedAt: t.Now()}})
}

func (t *throttleFixture) recordChallenge(seKey, nonce string) {
	t.RecordChallengeForIdentity(t.PublicationGeneration(), seKey, nonce, "", "")
}

func (t *throttleFixture) matchChallenge(seKey, nonce string) bool {
	return t.MatchChallengeForIdentity(seKey, nonce, "", "")
}
