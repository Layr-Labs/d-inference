package api

import (
	"context"
	"errors"
	"io"
	"mime"
	"net/http"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/sandboxcontrol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type sandboxUploadBeginRequest struct {
	TransferID string  `json:"transfer_id"`
	Path       string  `json:"path"`
	Size       *uint64 `json:"size"`
	SHA256     string  `json:"sha256"`
}

func (s *Server) handleSandboxUploadBegin(w http.ResponseWriter, r *http.Request) {
	var request sandboxUploadBeginRequest
	if !decodeStrictSandboxJSON(w, r, &request) {
		return
	}
	s.relaySandboxFile(w, r, sandboxcontrol.FileRequest{
		Operation: protocol.SandboxFileUploadBegin, TransferID: &request.TransferID,
		Path: &request.Path, Size: request.Size, SHA256: &request.SHA256,
	})
}

func (s *Server) handleSandboxUploadChunk(w http.ResponseWriter, r *http.Request) {
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/octet-stream" {
		writeJSON(w, http.StatusUnsupportedMediaType, errorResponse("invalid_request_error", "file chunks require application/octet-stream"))
		return
	}
	offset, err := sandboxFileQueryUint(r, "offset", nil)
	if err != nil {
		writeSandboxAPIError(w, err)
		return
	}
	transferID := r.PathValue("transferID")
	if !validSandboxAPIUUID(transferID) {
		writeSandboxAPIError(w, store.ErrNotFound)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, protocol.SandboxMaximumFileChunkBytes)
	data, err := io.ReadAll(r.Body)
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			writeJSON(w, http.StatusRequestEntityTooLarge, errorResponse("invalid_request_error", "sandbox file chunk exceeds 512 KiB"))
		} else {
			writeSandboxAPIError(w, sandboxcontrol.ErrInvalidRequest)
		}
		return
	}
	s.relaySandboxFile(w, r, sandboxcontrol.FileRequest{
		Operation: protocol.SandboxFileUploadChunk, TransferID: &transferID, Offset: &offset, Data: data,
	})
}

func (s *Server) handleSandboxUploadStatus(w http.ResponseWriter, r *http.Request) {
	s.relaySandboxTransfer(w, r, protocol.SandboxFileUploadStatus)
}

func (s *Server) handleSandboxUploadCommit(w http.ResponseWriter, r *http.Request) {
	s.relaySandboxTransfer(w, r, protocol.SandboxFileUploadCommit)
}

func (s *Server) handleSandboxUploadAbort(w http.ResponseWriter, r *http.Request) {
	s.relaySandboxTransfer(w, r, protocol.SandboxFileUploadAbort)
}

func (s *Server) relaySandboxTransfer(w http.ResponseWriter, r *http.Request, operation string) {
	id := r.PathValue("transferID")
	if !validSandboxAPIUUID(id) {
		writeSandboxAPIError(w, store.ErrNotFound)
		return
	}
	s.relaySandboxFile(w, r, sandboxcontrol.FileRequest{Operation: operation, TransferID: &id})
}

func (s *Server) handleSandboxFileMkdir(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Path string `json:"path"`
	}
	if !decodeStrictSandboxJSON(w, r, &request) {
		return
	}
	s.relaySandboxFile(w, r, sandboxcontrol.FileRequest{Operation: protocol.SandboxFileMkdir, Path: &request.Path})
}

func (s *Server) handleSandboxFileDownload(w http.ResponseWriter, r *http.Request) {
	zero, chunkLimit := uint64(0), uint64(protocol.SandboxMaximumFileChunkBytes)
	offset, offsetErr := sandboxFileQueryUint(r, "offset", &zero)
	size, sizeErr := sandboxFileQueryUint(r, "length", &chunkLimit)
	path := r.URL.Query().Get("path")
	if offsetErr != nil || sizeErr != nil || len(r.URL.Query()["path"]) != 1 {
		writeSandboxAPIError(w, sandboxcontrol.ErrInvalidRequest)
		return
	}
	var version *string
	if values, exists := r.URL.Query()["version"]; exists {
		if len(values) != 1 {
			writeSandboxAPIError(w, sandboxcontrol.ErrInvalidRequest)
			return
		}
		version = &values[0]
	}
	s.relaySandboxFile(w, r, sandboxcontrol.FileRequest{
		Operation: protocol.SandboxFileDownload, Path: &path, Offset: &offset, Size: &size, Version: version,
	})
}

func (s *Server) relaySandboxFile(w http.ResponseWriter, r *http.Request, request sandboxcontrol.FileRequest) {
	sandboxID := r.PathValue("sandboxID")
	if !validSandboxAPIUUID(sandboxID) {
		writeSandboxAPIError(w, store.ErrNotFound)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	result, err := s.sandboxes.FileOperation(r.Context(), consumerKeyFromContext(r.Context()), sandboxID, request)
	if err != nil {
		writeSandboxFileError(w, err)
		return
	}
	if !result.Success {
		status := http.StatusBadGateway
		switch *result.ErrorCode {
		case "invalid_workspace_path", "invalid_guest_request":
			status = http.StatusBadRequest
		case "transfer_not_found", "file_not_found":
			status = http.StatusNotFound
		case "transfer_conflict", "guest_busy", "upload_publication_uncertain", "upload_already_committed", "file_changed":
			status = http.StatusConflict
		}
		writeJSON(w, status, errorResponse("sandbox_file_error", "sandbox file operation failed", withCode(*result.ErrorCode)))
		return
	}
	if request.Operation == protocol.SandboxFileDownload {
		data, err := protocol.DecodeSandboxFileData(*result.Data)
		if err != nil {
			writeSandboxFileError(w, err)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Length", strconv.Itoa(len(data)))
		w.Header().Set("X-Sandbox-File-Size", strconv.FormatUint(*result.Size, 10))
		w.Header().Set("X-Sandbox-File-Offset", strconv.FormatUint(*result.Offset, 10))
		w.Header().Set("X-Sandbox-Chunk-SHA256", *result.SHA256)
		w.Header().Set("X-Sandbox-File-Version", *result.Version)
		w.Header().Set("Access-Control-Expose-Headers", "X-Sandbox-File-Size, X-Sandbox-File-Offset, X-Sandbox-Chunk-SHA256, X-Sandbox-File-Version")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(data)
		return
	}
	// The outer host envelope and scope are routing authority, not consumer
	// inputs. Return only the operation outcome and transfer metadata.
	writeJSON(w, http.StatusOK, struct {
		RequestID  string  `json:"request_id"`
		TransferID *string `json:"transfer_id,omitempty"`
		State      *string `json:"state,omitempty"`
		Offset     *uint64 `json:"offset,omitempty"`
		Size       *uint64 `json:"size,omitempty"`
		SHA256     *string `json:"sha256,omitempty"`
	}{result.RequestID, result.TransferID, result.State, result.Offset, result.Size, result.SHA256})
}

func sandboxFileQueryUint(r *http.Request, name string, fallback *uint64) (uint64, error) {
	values := r.URL.Query()[name]
	if len(values) == 0 && fallback != nil {
		return *fallback, nil
	}
	if len(values) != 1 || values[0] == "" {
		return 0, sandboxcontrol.ErrInvalidRequest
	}
	value, err := strconv.ParseUint(values[0], 10, 64)
	if err != nil {
		return 0, sandboxcontrol.ErrInvalidRequest
	}
	return value, nil
}

func writeSandboxFileError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, sandboxcontrol.ErrFileRelayTimeout), errors.Is(err, context.DeadlineExceeded):
		writeJSON(w, http.StatusGatewayTimeout, errorResponse("sandbox_file_timeout", "file operation outcome is uncertain; inspect transfer status before retrying"))
	case errors.Is(err, sandboxcontrol.ErrFileRelayBusy):
		w.Header().Set("Retry-After", "1")
		writeJSON(w, http.StatusTooManyRequests, errorResponse("sandbox_file_busy", "too many concurrent file operations"))
	case errors.Is(err, sandboxcontrol.ErrFilesUnsupported):
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("sandbox_files_unavailable", "sandbox host does not support file transfer"))
	default:
		writeSandboxAPIError(w, err)
	}
}
