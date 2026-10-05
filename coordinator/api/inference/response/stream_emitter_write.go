package response

import (
	"encoding/json"
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
)

func (e *completionsStreamEmitter) emit(value any) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return
	}
	n, werr := fmt.Fprintf(e.w, "data: %s\n\n", encoded)
	observation.MarkContentWrite(e.w, observation.GeneratedContentJSON(encoded), n, len(encoded)+8, werr)
	observation.MarkResponseTerminalWrite(e.w, observation.ResponseEventTerminals(encoded), n, len(encoded)+8, werr)
	if n != len(encoded)+8 {
		e.stamps.WriteErr()
	}
	e.flusher.Flush()
	e.stamps.Wrote(n, werr)
}

func (e *messagesStreamEmitter) emit(eventType string, fields map[string]any) {
	fields["type"] = eventType
	encoded, err := json.Marshal(fields)
	if err != nil {
		return
	}
	n, werr := fmt.Fprintf(e.w, "event: %s\ndata: %s\n\n", eventType, encoded)
	observation.MarkContentWrite(e.w, observation.GeneratedContentJSON(encoded), n, len(eventType)+len(encoded)+16, werr)
	observation.MarkResponseTerminalWrite(e.w, observation.ResponseEventTerminals(encoded), n, len(eventType)+len(encoded)+16, werr)
	if n != len(eventType)+len(encoded)+16 {
		e.stamps.WriteErr()
	}
	e.flusher.Flush()
	e.stamps.Wrote(n, werr)
}

// emit writes one SSE event with an event line and a sequence_number.
func (e *ResponsesStreamEmitter) emit(eventType string, fields map[string]any) {
	fields["type"] = eventType
	fields["sequence_number"] = e.seq
	e.seq++
	data, err := json.Marshal(fields)
	if err != nil {
		return
	}
	n, werr := fmt.Fprintf(e.w, "event: %s\ndata: %s\n\n", eventType, data)
	observation.MarkContentWrite(e.w, observation.GeneratedContentJSON(data), n, len(eventType)+len(data)+16, werr)
	observation.MarkResponseTerminalWrite(e.w, observation.ResponseEventTerminals(data), n, len(eventType)+len(data)+16, werr)
	if n != len(eventType)+len(data)+16 {
		e.stamps.WriteErr()
	}
	e.flusher.Flush()
	e.stamps.Wrote(n, werr)
}
