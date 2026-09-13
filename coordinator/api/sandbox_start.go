package api

import "net/http"

func (s *Server) handleStartSandbox(w http.ResponseWriter, r *http.Request) {
	s.handleSandboxOperation(w, r, s.sandboxes.Start)
}
