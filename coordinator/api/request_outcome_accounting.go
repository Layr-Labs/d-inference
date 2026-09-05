package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/outcomes"
)

func inferenceOutcomeEndpoint(r *http.Request) bool {
	if r.Method != http.MethodPost {
		return false
	}
	switch r.URL.Path {
	case "/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages":
		return true
	}
	return false
}

func requestOutcomeFromContext(ctx context.Context) *outcomes.Tracker {
	if m := requestMetaFromContext(ctx); m != nil {
		return m.outcome
	}
	return nil
}

// Read only the response envelope already assembled by the adapter. Accounting
// never reparses or retains generated response bytes.
func responseAccountingTerminal(v any) string {
	status := "completed"
	switch response := v.(type) {
	case types.ResponsesResponse:
		if response.Error != nil {
			return "error"
		}
		status = response.Status
	case *types.ResponsesResponse:
		if response == nil {
			return "unknown"
		}
		return responseAccountingTerminal(*response)
	case map[string]any:
		if response["error"] != nil || response["type"] == "error" {
			return "error"
		}
		if response["object"] == "response" {
			status, _ = response["status"].(string)
		}
	}
	switch status {
	case "completed", "incomplete":
		return status
	case "failed":
		return "error"
	default:
		return "unknown"
	}
}

// Native Responses frames can pass through the chat relay without a generated
// [DONE]. Inspect only candidate terminal envelopes, independently of content.
func accountingStreamTerminal(frame string) string {
	if !strings.Contains(frame, "response.completed") && !strings.Contains(frame, "response.incomplete") && !strings.Contains(frame, "response.failed") {
		return ""
	}
	for line := range strings.SplitSeq(frame, "\n") {
		data, ok := strings.CutPrefix(line, "data:")
		if !ok {
			continue
		}
		var event struct {
			Type     string `json:"type"`
			Response struct {
				Status string `json:"status"`
			} `json:"response"`
		}
		if json.Unmarshal([]byte(data), &event) != nil {
			continue
		}
		switch event.Type {
		case "response.completed":
			if event.Response.Status == "completed" {
				return "completed"
			}
		case "response.incomplete":
			return "incomplete"
		case "response.failed":
			return "error"
		}
	}
	return ""
}
