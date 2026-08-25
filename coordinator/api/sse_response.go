package api

import "net/http"

// writeSSEResponseHeader commits the streaming response only after dispatch has
// received real content. Pre-content paths must retain status-code ownership.
func writeSSEResponseHeader(w http.ResponseWriter, jobID string) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	// X-Request-ID is set by the logging middleware to the trace ID. The internal
	// job UUID can change across retries, so surface it under its own header for
	// callers correlating to provider-side logs.
	if jobID != "" {
		w.Header().Set("X-Inference-Job-ID", jobID)
	}
	w.WriteHeader(http.StatusOK)
}
