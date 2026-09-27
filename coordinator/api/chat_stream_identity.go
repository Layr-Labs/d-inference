package api

import (
	"encoding/json"
	"strings"
)

// chatStreamIdentity belongs to one consumer relay goroutine. Observe the
// first valid Chat envelope; never rewrite provider frames or their contents.
// Coordinator-authored terminal extras must belong to that same response.
type chatStreamIdentity struct {
	id      string
	created *int64
}

func (identity *chatStreamIdentity) observe(chunk string) {
	if identity.id != "" {
		return
	}
	// Reuse the security filters' SSE event grouping, including decorated,
	// multiline and coalesced events. Returning changed=false preserves bytes.
	_ = sanitizeStreamJSONEvents(chunk, func(raw string) (string, bool) {
		if identity.id != "" {
			return raw, false
		}
		var object map[string]json.RawMessage
		if json.Unmarshal([]byte(raw), &object) != nil {
			return raw, false
		}
		var kind, id string
		_ = json.Unmarshal(object["object"], &kind)
		if kind != "chat.completion.chunk" {
			if kind != "" || !strings.HasPrefix(strings.TrimSpace(string(object["choices"])), "[") {
				return raw, false
			}
		}
		if json.Unmarshal(object["id"], &id) != nil || id == "" {
			return raw, false
		}
		identity.id = id
		if value := strings.TrimSpace(string(object["created"])); value != "" && value != "null" {
			var created int64
			if json.Unmarshal([]byte(value), &created) == nil && created >= 0 {
				identity.created = &created
			}
		}
		return raw, false
	})
}
