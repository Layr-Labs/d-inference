package response

import (
	"encoding/json"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"net/http"
	"strings"
)

// responsesStreamEmitter translates provider chat.completion.chunk deltas into
// incremental OpenAI Responses API SSE events. Every event carries an `event:`
// line and a monotonically increasing sequence_number, matching the official
// Responses streaming wire format.
type responsesStreamEmitter struct {
	observer WriteObserver
	w        http.ResponseWriter
	flusher  http.Flusher
	pr       *registry.PendingRequest
	stamps   *relayStamps

	responseID string
	createdAt  int64
	model      string
	seq        int

	outputIndex int
	output      []any

	reasoningOpen   bool
	reasoningItemID string
	reasoningBuf    strings.Builder

	messageOpen   bool
	messageItemID string
	contentBuf    strings.Builder

	activeFnByIndex map[int]*streamFnState
	fnOrder         []*streamFnState
	sawToolCall     bool

	finishReason string
}

// streamFnState tracks one in-progress function_call output item, keyed by
// the provider chunk's tool_calls[].index.
type streamFnState struct {
	outputIndex int
	itemID      string
	callID      string
	wireID      string
	name        string
	argsBuf     strings.Builder
}

func newResponsesStreamEmitter(w http.ResponseWriter, flusher http.Flusher, pr *registry.PendingRequest, responseID string, createdAt int64, observer WriteObserver) *responsesStreamEmitter {
	return &responsesStreamEmitter{observer: observer,
		w:               w,
		flusher:         flusher,
		pr:              pr,
		stamps:          newRelayStamps(pr.Profile.Parent()),
		responseID:      responseID,
		createdAt:       createdAt,
		model:           ConsumerModel(pr),
		activeFnByIndex: map[int]*streamFnState{},
	}
}

// emit writes one SSE event with an `event:` line and a sequence_number.
func (e *responsesStreamEmitter) emit(eventType string, fields map[string]any) {
	fields["type"] = eventType
	fields["sequence_number"] = e.seq
	e.seq++
	data, err := json.Marshal(fields)
	if err != nil {
		return
	}
	n, werr := fmt.Fprintf(e.w, "event: %s\ndata: %s\n\n", eventType, data)
	observeContentWrite(e.observer, e.w, GeneratedContentJSON(data), n, len(eventType)+len(data)+16, werr)
	observeTerminalWrite(e.observer, e.w, responseEventTerminals(data), n, len(eventType)+len(data)+16, werr)
	if n != len(eventType)+len(data)+16 {
		e.stamps.writeErr()
	}
	e.flusher.Flush()
	e.stamps.wrote(n, werr)
}

// start emits response.created and response.in_progress.
func (e *responsesStreamEmitter) Start() {
	e.emit("response.created", map[string]any{
		"response": responsesSnapshot(e.responseID, e.createdAt, e.model, "in_progress", nil, nil, nil, e.pr.Traits),
	})
	e.emit("response.in_progress", map[string]any{
		"response": responsesSnapshot(e.responseID, e.createdAt, e.model, "in_progress", nil, nil, nil, e.pr.Traits),
	})
}

// NewResponsesSink formats chat deltas as the OpenAI Responses event protocol.
func NewResponsesSink(w http.ResponseWriter, flusher http.Flusher, pr *registry.PendingRequest, responseID string, createdAt int64, observer WriteObserver) EndpointSink {
	return newResponsesStreamEmitter(w, flusher, pr, responseID, createdAt, observer)
}
