package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/sandboxcontrol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

const sandboxGibibyte = uint64(1024 * 1024 * 1024)

type createSandboxRequest struct {
	BaseImageID  string `json:"base_image_id"`
	CPUCount     uint16 `json:"cpu_count"`
	MemoryGiB    uint64 `json:"memory_gib"`
	WorkspaceGiB uint64 `json:"workspace_gib"`
	GPU          bool   `json:"gpu"`
}

type sandboxCommandRequest struct {
	IdempotencyKey   string            `json:"idempotency_key,omitempty"`
	Arguments        []string          `json:"arguments"`
	Environment      map[string]string `json:"environment,omitempty"`
	WorkingDirectory string            `json:"working_directory,omitempty"`
	TimeoutSeconds   uint32            `json:"timeout_seconds,omitempty"`
}

type sandboxOperationResponse struct {
	Sandbox   *store.SandboxRecord    `json:"sandbox,omitempty"`
	Operation *store.SandboxOperation `json:"operation"`
}

type sandboxCommandResponse struct {
	Command *store.SandboxCommand `json:"command"`
}

type sandboxListResponse struct {
	Data []store.SandboxRecord `json:"data"`
}

func (s *Server) handleCreateSandbox(w http.ResponseWriter, r *http.Request) {
	var request createSandboxRequest
	if !decodeStrictSandboxJSON(w, r, &request) {
		return
	}
	memoryBytes, memoryOverflow := multiplyUint64(
		request.MemoryGiB,
		sandboxGibibyte,
	)
	workspaceBytes, workspaceOverflow := multiplyUint64(
		request.WorkspaceGiB,
		sandboxGibibyte,
	)
	if memoryOverflow || workspaceOverflow {
		writeSandboxAPIError(w, sandboxcontrol.ErrInvalidRequest)
		return
	}
	sandbox, operation, err := s.sandboxes.Create(
		r.Context(),
		consumerKeyFromContext(r.Context()),
		keyIDFromContext(r.Context()),
		sandboxcontrol.CreateRequest{
			BaseImageID:    request.BaseImageID,
			CPUCount:       request.CPUCount,
			MemoryBytes:    memoryBytes,
			WorkspaceBytes: workspaceBytes,
			GPU:            request.GPU,
		},
	)
	if err != nil {
		writeSandboxAPIError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, sandboxOperationResponse{
		Sandbox:   sandbox,
		Operation: operation,
	})
}

func (s *Server) handleListSandboxes(w http.ResponseWriter, r *http.Request) {
	limit := 100
	if encoded := r.URL.Query().Get("limit"); encoded != "" {
		parsed, err := strconv.Atoi(encoded)
		if err != nil || parsed <= 0 || parsed > store.MaxSandboxListLimit {
			writeSandboxAPIError(w, sandboxcontrol.ErrInvalidRequest)
			return
		}
		limit = parsed
	}
	sandboxes, err := s.sandboxes.List(
		r.Context(),
		consumerKeyFromContext(r.Context()),
		limit,
	)
	if err != nil {
		writeSandboxAPIError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sandboxListResponse{Data: sandboxes})
}

func (s *Server) handleGetSandbox(w http.ResponseWriter, r *http.Request) {
	sandboxID := r.PathValue("sandboxID")
	if !validSandboxAPIUUID(sandboxID) {
		writeSandboxAPIError(w, store.ErrNotFound)
		return
	}
	sandbox, err := s.sandboxes.Get(
		r.Context(),
		consumerKeyFromContext(r.Context()),
		sandboxID,
	)
	if err != nil {
		writeSandboxAPIError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sandbox)
}

func (s *Server) handleSandboxCommand(w http.ResponseWriter, r *http.Request) {
	sandboxID := r.PathValue("sandboxID")
	if !validSandboxAPIUUID(sandboxID) {
		writeSandboxAPIError(w, store.ErrNotFound)
		return
	}
	var request sandboxCommandRequest
	if !decodeStrictSandboxJSON(w, r, &request) {
		return
	}
	headerKey := r.Header.Get("Idempotency-Key")
	if request.IdempotencyKey == "" {
		request.IdempotencyKey = headerKey
	} else if headerKey != "" && headerKey != request.IdempotencyKey {
		writeSandboxAPIError(w, sandboxcontrol.ErrInvalidRequest)
		return
	}
	command, err := s.sandboxes.Execute(
		r.Context(),
		consumerKeyFromContext(r.Context()),
		sandboxID,
		sandboxcontrol.CommandRequest{
			IdempotencyKey:   request.IdempotencyKey,
			Arguments:        request.Arguments,
			Environment:      request.Environment,
			WorkingDirectory: request.WorkingDirectory,
			TimeoutSeconds:   request.TimeoutSeconds,
		},
	)
	if err != nil {
		writeSandboxAPIError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, sandboxCommandResponse{Command: command})
}

func (s *Server) handleGetSandboxCommand(w http.ResponseWriter, r *http.Request) {
	sandboxID := r.PathValue("sandboxID")
	commandID := r.PathValue("commandID")
	if !validSandboxAPIUUID(sandboxID) || !validSandboxAPIUUID(commandID) {
		writeSandboxAPIError(w, store.ErrNotFound)
		return
	}
	command, err := s.sandboxes.GetCommand(
		r.Context(),
		consumerKeyFromContext(r.Context()),
		sandboxID,
		commandID,
	)
	if err != nil {
		writeSandboxAPIError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sandboxCommandResponse{Command: command})
}

func (s *Server) handleRenewSandbox(w http.ResponseWriter, r *http.Request) {
	s.handleSandboxOperation(w, r, s.sandboxes.Renew)
}

func (s *Server) handleStopSandbox(w http.ResponseWriter, r *http.Request) {
	s.handleSandboxOperation(w, r, s.sandboxes.Stop)
}

func (s *Server) handleDeleteSandbox(w http.ResponseWriter, r *http.Request) {
	s.handleSandboxOperation(w, r, s.sandboxes.Terminate)
}

func (s *Server) handleSandboxOperation(
	w http.ResponseWriter,
	r *http.Request,
	run func(
		context.Context,
		string,
		string,
	) (*store.SandboxOperation, error),
) {
	sandboxID := r.PathValue("sandboxID")
	if !validSandboxAPIUUID(sandboxID) {
		writeSandboxAPIError(w, store.ErrNotFound)
		return
	}
	operation, err := run(
		r.Context(),
		consumerKeyFromContext(r.Context()),
		sandboxID,
	)
	if err != nil {
		writeSandboxAPIError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, sandboxOperationResponse{
		Operation: operation,
	})
}

func (s *Server) handleGetSandboxOperation(
	w http.ResponseWriter,
	r *http.Request,
) {
	operationID := r.PathValue("operationID")
	if !validSandboxAPIUUID(operationID) {
		writeSandboxAPIError(w, store.ErrNotFound)
		return
	}
	operation, err := s.sandboxes.GetOperation(
		r.Context(),
		consumerKeyFromContext(r.Context()),
		operationID,
	)
	if err != nil {
		writeSandboxAPIError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sandboxOperationResponse{
		Operation: operation,
	})
}

func decodeStrictSandboxJSON(
	w http.ResponseWriter,
	r *http.Request,
	target any,
) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxControlPlaneBodyBytes)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		var maxError *http.MaxBytesError
		if errors.As(err, &maxError) {
			writeJSON(
				w,
				http.StatusRequestEntityTooLarge,
				errorResponse("invalid_request_error", "request body too large"),
			)
			return false
		}
		writeSandboxAPIError(w, sandboxcontrol.ErrInvalidRequest)
		return false
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		writeSandboxAPIError(w, sandboxcontrol.ErrInvalidRequest)
		return false
	}
	return true
}

func writeSandboxAPIError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeJSON(
			w,
			http.StatusNotFound,
			errorResponse("sandbox_not_found", "sandbox resource not found"),
		)
	case errors.Is(err, sandboxcontrol.ErrInvalidRequest):
		writeJSON(
			w,
			http.StatusBadRequest,
			errorResponse("invalid_request_error", "invalid sandbox request"),
		)
	case errors.Is(err, sandboxcontrol.ErrNoCapacity):
		w.Header().Set("Retry-After", "5")
		writeJSON(
			w,
			http.StatusTooManyRequests,
			errorResponse("sandbox_capacity_exhausted", "no sandbox host has capacity"),
		)
	case errors.Is(err, sandboxcontrol.ErrHostUnavailable):
		writeJSON(
			w,
			http.StatusServiceUnavailable,
			errorResponse("sandbox_host_unavailable", "sandbox host unavailable"),
		)
	case sandboxcontrol.IsConflict(err):
		writeJSON(
			w,
			http.StatusConflict,
			errorResponse("sandbox_state_conflict", "sandbox state changed"),
		)
	default:
		writeJSON(
			w,
			http.StatusInternalServerError,
			errorResponse("internal_error", "sandbox operation failed"),
		)
	}
}

func validSandboxAPIUUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	_, err := uuid.Parse(value)
	return err == nil
}

func multiplyUint64(
	value uint64,
	multiplier uint64,
) (uint64, bool) {
	if value != 0 && multiplier > ^uint64(0)/value {
		return 0, true
	}
	return value * multiplier, false
}
