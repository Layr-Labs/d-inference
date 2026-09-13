package api

import (
	"net/http"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/sandboxcontrol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Server) handleListSandboxCommands(w http.ResponseWriter, r *http.Request) {
	sandboxID := r.PathValue("sandboxID")
	if !validSandboxAPIUUID(sandboxID) {
		writeSandboxAPIError(w, store.ErrNotFound)
		return
	}
	limit := 100
	if encoded := r.URL.Query().Get("limit"); encoded != "" {
		parsed, err := strconv.Atoi(encoded)
		if err != nil || parsed <= 0 || parsed > store.MaxSandboxListLimit {
			writeSandboxAPIError(w, sandboxcontrol.ErrInvalidRequest)
			return
		}
		limit = parsed
	}
	commands, err := s.sandboxes.ListCommands(r.Context(), consumerKeyFromContext(r.Context()), sandboxID, limit)
	if err != nil {
		writeSandboxAPIError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, struct {
		Data []store.SandboxCommandSummary `json:"data"`
	}{Data: commands})
}

func (s *Server) handleCancelSandboxCommand(w http.ResponseWriter, r *http.Request) {
	sandboxID, commandID := r.PathValue("sandboxID"), r.PathValue("commandID")
	if !validSandboxAPIUUID(sandboxID) || !validSandboxAPIUUID(commandID) {
		writeSandboxAPIError(w, store.ErrNotFound)
		return
	}
	command, err := s.sandboxes.CancelCommand(r.Context(), consumerKeyFromContext(r.Context()), sandboxID, commandID)
	if err != nil {
		writeSandboxAPIError(w, err)
		return
	}
	status := http.StatusOK
	if command.CancellationPending {
		status = http.StatusAccepted
	}
	writeJSON(w, status, sandboxCommandResponse{Command: command})
}
