// Package response formats consumer inference responses and relays provider output.
// Settlement, routing feedback and HTTP outcome recording remain explicit caller
// dependencies; the writer does not own a server, ledger or provider registry.
package response

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// InferenceTimeout bounds idle streaming time or a complete non-streaming reply.
const InferenceTimeout = 600 * time.Second

// Reservation preserves the pending request's existing settlement arbitration.
type Reservation interface {
	Refund(*registry.PendingRequest, string) bool
}

// Feedback records provider outcomes without changing dispatch policy.
type Feedback interface {
	Error(string, *registry.PendingRequest, int, string, string, string, ...protocol.CoordinatorInferenceErrorCause)
	Success(*registry.PendingRequest)
}

// Outcomes records the existing route outcome at each response lifecycle boundary.
// committed distinguishes an in-band failure from a failure before a response.
type Outcomes interface {
	ProviderError(*registry.PendingRequest, protocol.InferenceErrorMessage, bool)
	Incomplete(*registry.PendingRequest, bool)
	Timeout(*registry.PendingRequest, bool, string)
	ClientGone(*registry.PendingRequest)
}

// Metrics receives the existing low-cardinality relay counters.
type Metrics interface{ Incr(string, []string) }

// ErrorPolicy applies the API's provider-error status and safe envelope policy.
type ErrorPolicy interface {
	WriteProviderError(http.ResponseWriter, protocol.InferenceErrorMessage)
}

// WriteObserver receives evidence after a sink accepts output. The caller decides
// whether a writer is the transport or an intermediate buffer, such as a sealing
// writer. Short and failed writes are supplied unchanged for that decision.
type WriteObserver interface {
	ContentWrite(http.ResponseWriter, bool, int, int, error)
	TerminalWrite(http.ResponseWriter, Terminals, int, int, error)
}

// Dependencies are the request lifecycle operations shared with ingress/settlement.
// Observer is optional for callers that do not collect HTTP outcome evidence.
type Dependencies struct {
	Reservation Reservation
	Feedback    Feedback
	Outcomes    Outcomes
	Metrics     Metrics
	Errors      ErrorPolicy
	Observer    WriteObserver
}

// Writer relays one request at a time using caller-owned lifecycle services.
// Relay state is local to each invocation, so a Writer may be shared.
type Writer struct{ deps Dependencies }

func New(deps Dependencies) *Writer { return &Writer{deps: deps} }

func observeContentWrite(observer WriteObserver, w http.ResponseWriter, content bool, n, expected int, err error) {
	if observer != nil {
		observer.ContentWrite(w, content, n, expected, err)
	}
}

func observeTerminalWrite(observer WriteObserver, w http.ResponseWriter, terminals Terminals, n, expected int, err error) {
	if observer != nil {
		observer.TerminalWrite(w, terminals, n, expected, err)
	}
}
