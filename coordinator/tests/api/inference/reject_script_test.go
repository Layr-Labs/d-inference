package inference_test

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// rejectScript makes every dispatch reject pre-content with (errMsg, status) and
// NO chunks — the shape of a provider token-budget admission rejection.
func rejectScript(errMsg string, status int) inferenceScript {
	return func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		fp.sendInferenceError(ctx, req, errMsg, status)
	}
}
