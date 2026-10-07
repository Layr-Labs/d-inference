package shared

import "encoding/json"

// jsonbParam returns nil (SQL NULL) for an empty RawMessage so an empty value
// never reaches JSONB as an invalid zero-length document (mirrors the
// request_rejections params handling).
func JsonbParam(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 {
		return nil
	}
	return raw
}
