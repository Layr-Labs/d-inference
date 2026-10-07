package exchange_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/exchange"
	recovery "github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestAppAttestShadowLateProofCannotWinTimerRace(t *testing.T) {
	x := exchange.Challenge{Expected: "assertion", Started: time.Now().Add(-recovery.ResponseTimeout - time.Second)}
	if got := exchange.Verify(context.Background(), exchange.Dependencies{}, x, protocol.AppAttestShadowPayload{Result: "ok"}).Next; got != "stop" {
		t.Fatalf("late proof handled: %s", got)
	}
}
