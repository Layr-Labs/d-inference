package autopilot

import (
	"encoding/json"
	"net/http"
)

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func errorResponse(kind, message string) map[string]any {
	return map[string]any{"error": map[string]any{"type": kind, "code": kind, "message": message}}
}
