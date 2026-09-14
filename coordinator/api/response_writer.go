package api

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// responseWriter binds formatting to the same settlement, routing feedback and
// accepted-write evidence used by the rest of the request lifecycle.
func (s *Server) responseWriter() *response.Writer {
	binding := responseServices{s}
	return response.New(response.Dependencies{
		Reservation: binding, Feedback: s.inferenceAttempts(), Outcomes: binding,
		Metrics: binding, Errors: binding, Observer: responseWriteObserver{},
	})
}

func (s *Server) handleStreamingResponseWithFirstChunkAndError(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunks []string, initialError *protocol.InferenceErrorMessage) {
	s.responseWriter().Stream(w, r, pr, firstChunks, initialError)
}

func (s *Server) handleNonStreamingResponseWithFirstChunkAndError(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunks []string, initialError *protocol.InferenceErrorMessage) {
	s.responseWriter().NonStream(w, r, pr, firstChunks, initialError)
}

type responseServices struct{ server *Server }

func (b responseServices) Refund(pr *registry.PendingRequest, reference string) bool {
	return b.server.inferenceSettlement().Refund(pr, reference)
}
func (b responseServices) Incr(name string, tags []string) { b.server.ddIncr(name, tags) }
func (b responseServices) WriteProviderError(w http.ResponseWriter, err protocol.InferenceErrorMessage) {
	b.server.writeGenericProviderError(w, err)
}

func (b responseServices) ProviderError(pr *registry.PendingRequest, err protocol.InferenceErrorMessage, committed bool) {
	if committed {
		b.server.updateInferenceRouteOutcomeForPending(pr, attempt.PostCommitProviderErrorOutcome(pr, err))
	} else {
		b.server.updateInferenceRouteOutcomeForPending(pr, attempt.PreResponseProviderErrorOutcome(pr, err))
	}
}
func (b responseServices) Incomplete(pr *registry.PendingRequest, committed bool) {
	if committed {
		b.server.updateInferenceRouteOutcomeForPending(pr, attempt.PostCommitProviderIncompleteOutcome(pr))
	} else {
		b.server.updateInferenceRouteOutcomeForPending(pr, attempt.PreResponseProviderIncompleteOutcome(pr))
	}
}
func (b responseServices) Timeout(pr *registry.PendingRequest, committed bool, class string) {
	if committed {
		b.server.updateInferenceRouteOutcomeForPending(pr, attempt.PostCommitStreamTimeoutOutcome(pr))
	} else {
		b.server.updateInferenceRouteOutcomeForPending(pr, attempt.PreResponseTimeoutOutcome(pr, class))
	}
}
func (b responseServices) ClientGone(pr *registry.PendingRequest) {
	b.server.updateInferenceRouteOutcomeForPending(pr, attempt.ClientGoneBeforeResponseOutcome(pr))
}

// These existing API operations retain the sealing-writer guard and outcome lock.
type responseWriteObserver struct{}

func (responseWriteObserver) ContentWrite(w http.ResponseWriter, content bool, n, expected int, err error) {
	markContentWrite(w, content, n, expected, err)
}
func (responseWriteObserver) TerminalWrite(w http.ResponseWriter, terminals response.Terminals, n, expected int, err error) {
	markResponseTerminalWrite(w, terminals, n, expected, err)
}
