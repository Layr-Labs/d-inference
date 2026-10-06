package input

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// DrainStopped archives already-accepted frames after admission has closed.
// Each frame retains an independent background completion budget.
func DrainStopped(in <-chan protocol.AppAttestShadowPayload, handle func(context.Context, protocol.AppAttestShadowPayload)) {
	for {
		select {
		case reply := <-in:
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			handle(ctx, reply)
			cancel()
		default:
			return
		}
	}
}
