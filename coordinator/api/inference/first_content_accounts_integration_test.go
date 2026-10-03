package inference

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestFirstContentSLAExemptionSurvivesFailover(t *testing.T) {
	reg, _, _, ts := setupTTFTFailoverServerWithConfig(t, TestServerConfig{FirstContentDeadlineBase: 50 * time.Millisecond, FirstContentSLAAccounts: []string{}})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	const model = "exempt-retry-model"
	var attempts deadlineAttemptRecorder
	script := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
		attempt := attempts.capture(t, reg, fp, req)
		if attempt == 1 {
			fp.sendTypedInferenceError(ctx, req, protocol.FailureCodeCapacity, errorReasonCapacityBusy, http.StatusServiceUnavailable)
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(120 * time.Millisecond):
		}
		fp.serveFull(ctx, req, model, "RETRY_OK")
	}
	for i := 0; i < 2; i++ {
		startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{Name: fmt.Sprintf("exempt-retry-%d", i), Version: "0.8.15", DecodeTPS: float64(200 - i*50), Models: []failoverModelSpec{{ID: model}}, Script: script})
	}
	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil || status != http.StatusOK || !strings.Contains(body, "RETRY_OK") {
		t.Fatalf("retry: %d %v %s", status, err, body)
	}
	seen := attempts.snapshot()
	if len(seen) != 2 {
		t.Fatalf("attempts=%+v", seen)
	}
	for _, attempt := range seen {
		if attempt.wireMS != 0 || attempt.maxTTFTMS != 0 {
			t.Fatalf("retry reinstated SLA: %+v", attempt)
		}
	}
}
