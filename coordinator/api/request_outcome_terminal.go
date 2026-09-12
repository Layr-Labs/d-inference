package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
)

// responseTerminals retains at most two different closed values. Repeated
// matching events are idempotent; contradictory events remain visible whether
// they arrive in separate writes, coalesced writes, or one provider SSE group.
// It never retains content or arbitrary provider strings.
type responseTerminals struct {
	first, conflicting string
}

func (t *responseTerminals) observe(value string) {
	if value == "" || value == "unknown" {
		return
	}
	if t.first == "" {
		t.first = value
	} else if t.first != value && t.conflicting == "" {
		t.conflicting = value
	}
}

func markResponseTerminalWrite(w http.ResponseWriter, terminals responseTerminals, n, expected int, err error) {
	if err != nil || n != expected || terminals.first == "" {
		return
	}
	// Plaintext acceptance by this buffer is not an outer transport write.
	// The sealing writer records each terminal after writing its ciphertext.
	if _, sealed := w.(*sealingResponseWriter); sealed {
		return
	}
	if o := outcomeForWriter(w); o != nil {
		o.mu.Lock()
		defer o.mu.Unlock()
		for _, terminal := range []string{terminals.first, terminals.conflicting} {
			if terminal == "" {
				continue
			}
			if o.record.ResponseTerminal == "" || o.record.ResponseTerminal == "unknown" {
				o.record.ResponseTerminal = terminal
			} else if o.record.ResponseTerminal != terminal {
				o.record.EvidenceConflict = true
			}
		}
		o.record.EgressCompleted = true
	}
}

// responseBodyTerminals recognizes only supported full JSON response shapes.
// An arbitrary 200, unrecognized status, or malformed body is not completion.
func responseBodyTerminals(data []byte) responseTerminals {
	var v struct {
		Object  string          `json:"object"`
		Type    string          `json:"type"`
		Status  string          `json:"status"`
		Error   json.RawMessage `json:"error"`
		Choices json.RawMessage `json:"choices"`
	}
	if json.Unmarshal(data, &v) != nil {
		return responseTerminals{}
	}
	var terminals responseTerminals
	if hasJSONError(v.Error) || v.Type == "error" {
		terminals.observe("error")
	}
	switch {
	case v.Object == "response":
		terminals.observe(responseStatusTerminal(v.Status))
	case v.Type == "message" || completedChoices(v.Choices):
		terminals.observe("completed")
	}
	return terminals
}

// Full chat/text responses carry an array of choices containing a message
// object or a text string. Raw key presence also matches null/scalars and must
// not promote malformed output into a completed response.
func completedChoices(raw json.RawMessage) bool {
	var choices []map[string]json.RawMessage
	if json.Unmarshal(raw, &choices) != nil || len(choices) == 0 {
		return false
	}
	for _, choice := range choices {
		var message map[string]json.RawMessage
		var text *string
		if json.Unmarshal(choice["message"], &message) == nil && message != nil {
			continue
		}
		if json.Unmarshal(choice["text"], &text) == nil && text != nil {
			continue
		}
		return false
	}
	return true
}

func hasJSONError(raw json.RawMessage) bool {
	var object map[string]json.RawMessage
	return json.Unmarshal(raw, &object) == nil && object != nil
}

func responseStatusTerminal(status string) string {
	switch status {
	case "completed", "incomplete":
		return status
	case "failed":
		return "error"
	default:
		return ""
	}
}

// Ordinary content writes cannot establish a terminal. Keep the unsampled
// observer's fast negative path allocation-free; Unicode escapes take the
// parse path because they may encode an otherwise hidden type or error key.
func couldContainResponseTerminal(data []byte) bool {
	return bytes.Contains(data, []byte("[DONE]")) ||
		bytes.Contains(data, []byte("response.completed")) ||
		bytes.Contains(data, []byte("response.incomplete")) ||
		bytes.Contains(data, []byte("response.failed")) ||
		bytes.Contains(data, []byte("message_stop")) ||
		bytes.Contains(data, []byte(`"error"`)) ||
		bytes.Contains(data, []byte(`\u`))
}

func responseEventTerminals(data []byte) responseTerminals {
	if !couldContainResponseTerminal(data) {
		return responseTerminals{}
	}
	var v struct {
		Type     string          `json:"type"`
		Error    json.RawMessage `json:"error"`
		Response struct {
			Status string `json:"status"`
		} `json:"response"`
	}
	if json.Unmarshal(data, &v) != nil {
		return responseTerminals{}
	}
	var t responseTerminals
	if hasJSONError(v.Error) || v.Type == "error" {
		t.observe("error")
	}
	switch v.Type {
	case "response.completed", "response.incomplete", "response.failed":
		// Failure/incomplete event types already rule out fulfillment even if
		// an older provider omits the snapshot. Completion needs a recognized
		// snapshot too. Conflicting known snapshots remain visible.
		expected := responseStatusTerminal(v.Type[len("response."):])
		observed := responseStatusTerminal(v.Response.Status)
		if observed != "" || v.Type != "response.completed" {
			t.observe(expected)
			t.observe(observed)
		}
	case "message_stop":
		t.observe("completed")
	}
	return t
}

func responseStreamTerminals(frame []byte) responseTerminals {
	if !couldContainResponseTerminal(frame) {
		return responseTerminals{}
	}
	var terminals responseTerminals
	// SSE data lines within one event are joined with a newline before the
	// client parses JSON. Looking at each line separately would accept a valid
	// prefix followed by invalid data, and miss valid multiline JSON.
	normalized := strings.ReplaceAll(strings.ReplaceAll(string(frame), "\r\n", "\n"), "\r", "\n")
	for _, group := range strings.Split(normalized, "\n\n") {
		var data []string
		for _, line := range strings.Split(group, "\n") {
			if value, ok := sseDataValue(line); ok {
				data = append(data, value)
			}
		}
		payload := []byte(strings.Join(data, "\n"))
		if bytes.Equal(bytes.TrimSpace(payload), []byte("[DONE]")) {
			terminals.observe("completed")
		} else {
			t := responseEventTerminals(payload)
			terminals.observe(t.first)
			terminals.observe(t.conflicting)
		}
	}
	return terminals
}

func markOutcomePanic(r *http.Request) {
	if o := requestOutcomeFromContext(r.Context()); o != nil {
		o.mu.Lock()
		o.record.RawStage = "handler"
		o.record.RawReason = "handler_panic"
		o.mu.Unlock()
	}
}
