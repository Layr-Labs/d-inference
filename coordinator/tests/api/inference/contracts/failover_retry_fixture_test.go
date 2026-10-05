package inference_test

// Retry fixture for the scripted failover provider: the first dispatch fails
// before content and every later dispatch is served. Kept identical to the
// owner-test fixture in coordinator/tests/api/inference/failover_integration_test.go.

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"time"

	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

func (fp *failoverProvider) sendInferenceError(ctx context.Context, req protocol.InferenceRequestMessage, errMsg string, statusCode int) {
	failureCode, errorReason := testFailureClassification(errMsg, statusCode)
	msg := protocol.InferenceErrorMessage{
		Type:        protocol.TypeInferenceError,
		RequestID:   req.RequestID,
		Error:       errMsg,
		StatusCode:  statusCode,
		FailureCode: failureCode,
		ErrorReason: errorReason,
	}
	data, _ := json.Marshal(msg)
	if err := fp.conn.Write(ctx, websocket.MessageText, data); err != nil {
		fp.t.Logf("provider %s: write inference_error: %v", fp.name, err)
	}
}

// testFailureClassification migrates the shared fake provider to the typed
// protocol. String inspection is intentionally confined to test fixture setup;
// production classification never reads provider-authored Error prose.
func testFailureClassification(errMsg string, statusCode int) (protocol.InferenceFailureCode, string) {
	lower := strings.ToLower(errMsg)
	switch {
	case statusCode == 499:
		return protocol.FailureCodeCancelled, failure.ErrorReasonCancelled
	case strings.Contains(lower, "batch token budget"):
		return protocol.FailureCodeCapacity, failure.ErrorReasonRequestExceedsBatchBudget
	case strings.Contains(lower, "active token budget"):
		return protocol.FailureCodeCapacity, failure.ErrorReasonRequestExceedsNodeBudget
	case strings.Contains(lower, "context") && (strings.Contains(lower, "exceeds") || strings.Contains(lower, "exceeded")):
		return protocol.FailureCodeCapacity, failure.ErrorReasonRequestExceedsContext
	case strings.Contains(lower, "queue full"):
		return protocol.FailureCodeCapacity, failure.ErrorReasonQueueFull
	case statusCode == http.StatusTooManyRequests || statusCode == http.StatusServiceUnavailable:
		return protocol.FailureCodeCapacity, failure.ErrorReasonCapacityBusy
	case statusCode == http.StatusBadRequest:
		// A deterministic request-shape rejection. The raw text is still
		// discarded by the production sanitizer.
		return protocol.FailureCodeInvalidRequest, ""
	default:
		return protocol.FailureCodeGenerationFailure, ""
	}
}

// dispatchRecorder tracks the global order in which providers received
// dispatches, so failover tests are independent of which provider the
// scheduler happens to pick first.
type dispatchRecorder struct {
	mu    sync.Mutex
	order []string
}

func (d *dispatchRecorder) record(name string) int {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.order = append(d.order, name)
	return len(d.order)
}

func (d *dispatchRecorder) sequence() []string {
	d.mu.Lock()
	defer d.mu.Unlock()
	out := make([]string, len(d.order))
	copy(out, d.order)
	return out
}

// failFirstScript makes the provider that receives the globally-FIRST dispatch
// fail pre-content (role-only chunk, then failMode), while every later
// dispatch is served fully. failMode is "error" (inference_error 500) or
// "disconnect" (abrupt WebSocket drop after the role chunk).
func failFirstScript(rec *dispatchRecorder, model, failMode string) inferenceScript {
	return func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		seq := rec.record(fp.name)
		if seq == 1 {
			fp.sendRoleChunk(ctx, req, model)
			// Let the role chunk relay through the coordinator before the
			// failure signal so the "boilerplate already flowed" ordering is
			// deterministic.
			time.Sleep(40 * time.Millisecond)
			switch failMode {
			case "error":
				fp.sendInferenceError(ctx, req, "simulated backend failure", http.StatusInternalServerError)
			case "disconnect":
				fp.closeNow()
			default:
				fp.t.Errorf("unknown failMode %q", failMode)
			}
			return
		}
		fp.serveFull(ctx, req, model, markerFor(fp.name))
	}
}
