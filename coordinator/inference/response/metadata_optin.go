package response

import (
	"encoding/json"
	"net/http"
	"strings"
)

func truthyRequestFlag(v any) bool {
	switch x := v.(type) {
	case bool:
		return x
	case string:
		switch strings.ToLower(strings.TrimSpace(x)) {
		case "true", "1", "yes":
			return true
		}
	case float64:
		return x != 0
	case json.Number:
		n, err := x.Int64()
		return err == nil && n != 0
	}
	return false
}

func metadataDetailsRequested(parsed map[string]any, header http.Header) bool {
	if header != nil && truthyRequestFlag(header.Get(MetadataDetailsHeader)) {
		return true
	}
	if parsed != nil && truthyRequestFlag(parsed[metadataDetailsField]) {
		return true
	}
	return false
}

func stripMetadataDetailsFlag(parsed map[string]any) bool {
	if parsed == nil {
		return false
	}
	if _, ok := parsed[metadataDetailsField]; ok {
		delete(parsed, metadataDetailsField)
		return true
	}
	return false
}

// applyMetadataDetailsRequest consumes the coordinator-only metadata_details
// body flag (and/or X-Darkbloom-Metadata-Details header). The body field is
// stripped so it is never sealed into the provider payload. When the caller
// opted in, the header is set so dispatchOneProvider can stamp the pending
// request without threading another parameter. Returns whether parsed changed.
func ApplyMetadataDetailsRequest(r *http.Request, parsed map[string]any) bool {
	requested := false
	if r != nil {
		requested = metadataDetailsRequested(parsed, r.Header)
	} else {
		requested = metadataDetailsRequested(parsed, nil)
	}
	stripped := stripMetadataDetailsFlag(parsed)
	if requested && r != nil {
		if r.Header == nil {
			r.Header = make(http.Header)
		}
		r.Header.Set(MetadataDetailsHeader, "true")
	}
	return stripped
}

func MetadataDetailsFromRequest(r *http.Request) bool {
	if r == nil {
		return false
	}
	return metadataDetailsRequested(nil, r.Header)
}
