package protocol

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"
	"unicode/utf8"
)

const (
	SandboxTypeFileOperation            = "sandbox_file_operation"
	SandboxTypeFileResult               = "sandbox_file_result"
	SandboxFileUploadBegin              = "upload_begin"
	SandboxFileUploadChunk              = "upload_chunk"
	SandboxFileUploadStatus             = "upload_status"
	SandboxFileUploadCommit             = "upload_commit"
	SandboxFileUploadAbort              = "upload_abort"
	SandboxFileDownload                 = "download"
	SandboxFileMkdir                    = "mkdir"
	SandboxMaximumFileChunkBytes        = 512 * 1024
	SandboxMaximumFileBytes      uint64 = 50 * 1024 * 1024 * 1024
)

// File operations are bounded transient relay messages. Only transfer metadata
// and bytes are permitted; execution, guest credentials and runtime settings
// are never accepted by this seam.
type SandboxFileOperationPayload struct {
	RequestID  string       `json:"request_id"`
	Scope      SandboxScope `json:"scope"`
	Operation  string       `json:"operation"`
	TransferID *string      `json:"transfer_id,omitempty"`
	Path       *string      `json:"path,omitempty"`
	Offset     *uint64      `json:"offset,omitempty"`
	Size       *uint64      `json:"size,omitempty"`
	SHA256     *string      `json:"sha256,omitempty"`
	Data       *string      `json:"data,omitempty"`
	Version    *string      `json:"version,omitempty"`
}

type SandboxFileResultPayload struct {
	RequestID  string       `json:"request_id"`
	Scope      SandboxScope `json:"scope"`
	Operation  string       `json:"operation"`
	Success    bool         `json:"success"`
	ErrorCode  *string      `json:"error_code,omitempty"`
	TransferID *string      `json:"transfer_id,omitempty"`
	State      *string      `json:"state,omitempty"`
	Offset     *uint64      `json:"offset,omitempty"`
	Size       *uint64      `json:"size,omitempty"`
	SHA256     *string      `json:"sha256,omitempty"`
	Data       *string      `json:"data,omitempty"`
	Version    *string      `json:"version,omitempty"`
}

func ValidSandboxWorkspacePath(value string) bool {
	if value == "" || len(value) > 4096 || strings.HasPrefix(value, "/") ||
		strings.ContainsRune(value, 0) || !utf8.ValidString(value) {
		return false
	}
	for _, part := range strings.Split(value, "/") {
		if part == "" || part == "." || part == ".." || len(part) > 255 {
			return false
		}
	}
	return true
}

func ValidSandboxFileDigest(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, character := range []byte(value) {
		if !(character >= '0' && character <= '9') && !(character >= 'a' && character <= 'f') {
			return false
		}
	}
	return true
}

func DecodeSandboxFileData(value string) ([]byte, error) {
	if len(value) > base64.StdEncoding.EncodedLen(SandboxMaximumFileChunkBytes) {
		return nil, errors.New("sandbox file chunk exceeds limit")
	}
	decoded, err := base64.StdEncoding.Strict().DecodeString(value)
	if err != nil || len(decoded) > SandboxMaximumFileChunkBytes || base64.StdEncoding.EncodeToString(decoded) != value {
		return nil, errors.New("sandbox file chunk is not canonical base64")
	}
	return decoded, nil
}

func ValidateSandboxFileOperation(value *SandboxFileOperationPayload) error {
	invalid := errors.New("invalid sandbox file operation")
	if value == nil || !ValidSandboxUUID(value.RequestID) || validateSandboxScope(value.Scope) != nil {
		return invalid
	}
	if value.Version != nil && (value.Operation != SandboxFileDownload || !ValidSandboxFileDigest(*value.Version)) {
		return invalid
	}
	if value.TransferID != nil && !ValidSandboxUUID(*value.TransferID) ||
		value.Path != nil && !ValidSandboxWorkspacePath(*value.Path) ||
		value.Size != nil && *value.Size > SandboxMaximumFileBytes ||
		value.Offset != nil && *value.Offset > SandboxMaximumFileBytes ||
		value.SHA256 != nil && !ValidSandboxFileDigest(*value.SHA256) {
		return invalid
	}
	switch value.Operation {
	case SandboxFileUploadBegin:
		if value.TransferID == nil || value.Path == nil || value.Size == nil || value.SHA256 == nil || value.Offset != nil || value.Data != nil {
			return invalid
		}
	case SandboxFileUploadChunk:
		if value.TransferID == nil || value.Offset == nil || value.Data == nil || value.Path != nil || value.Size != nil || value.SHA256 != nil {
			return invalid
		}
		data, err := DecodeSandboxFileData(*value.Data)
		if err != nil || len(data) == 0 || uint64(len(data)) > SandboxMaximumFileBytes-*value.Offset {
			return invalid
		}
	case SandboxFileUploadStatus, SandboxFileUploadCommit, SandboxFileUploadAbort:
		if value.TransferID == nil || value.Path != nil || value.Size != nil || value.SHA256 != nil || value.Offset != nil || value.Data != nil {
			return invalid
		}
	case SandboxFileDownload:
		if value.Path == nil || value.Offset == nil || value.Size == nil || *value.Size == 0 || *value.Size > SandboxMaximumFileChunkBytes || value.TransferID != nil || value.Data != nil || value.SHA256 != nil {
			return invalid
		}
		if *value.Offset > 0 && value.Version == nil {
			return invalid
		}
	case SandboxFileMkdir:
		if value.Path == nil || value.TransferID != nil || value.Size != nil || value.SHA256 != nil || value.Offset != nil || value.Data != nil {
			return invalid
		}
	default:
		return invalid
	}
	return nil
}

func ValidateSandboxFileResult(value *SandboxFileResultPayload) error {
	invalid := errors.New("invalid sandbox file result")
	if value == nil || !ValidSandboxUUID(value.RequestID) || validateSandboxScope(value.Scope) != nil || !knownSandboxFileOperation(value.Operation) {
		return invalid
	}
	if value.Version != nil && (!value.Success || value.Operation != SandboxFileDownload || !ValidSandboxFileDigest(*value.Version)) {
		return invalid
	}
	if value.TransferID != nil && !ValidSandboxUUID(*value.TransferID) ||
		value.Size != nil && *value.Size > SandboxMaximumFileBytes ||
		value.Offset != nil && *value.Offset > SandboxMaximumFileBytes ||
		value.SHA256 != nil && !ValidSandboxFileDigest(*value.SHA256) {
		return invalid
	}
	if !value.Success {
		if value.ErrorCode == nil || !sandboxErrorCodePattern.MatchString(*value.ErrorCode) ||
			value.State != nil || value.Data != nil || value.Offset != nil || value.Size != nil || value.SHA256 != nil {
			return invalid
		}
		return nil
	}
	if value.ErrorCode != nil {
		return invalid
	}
	switch value.Operation {
	case SandboxFileUploadBegin, SandboxFileUploadChunk, SandboxFileUploadStatus, SandboxFileUploadCommit:
		if value.TransferID == nil || value.State == nil || value.Offset == nil || value.Size == nil || value.SHA256 == nil || value.Data != nil || *value.Offset > *value.Size {
			return invalid
		}
		if *value.State != "uploading" && *value.State != "committed" && *value.State != "aborted" {
			return invalid
		}
		if *value.State == "committed" && *value.Offset != *value.Size {
			return invalid
		}
	case SandboxFileUploadAbort:
		if value.TransferID == nil || value.State == nil || *value.State != "aborted" || value.Data != nil || value.Offset != nil || value.Size != nil || value.SHA256 != nil {
			return invalid
		}
	case SandboxFileDownload:
		if value.Data == nil || value.Offset == nil || value.Size == nil || value.SHA256 == nil || value.Version == nil || value.TransferID != nil || value.State != nil || *value.Offset > *value.Size {
			return invalid
		}
		data, err := DecodeSandboxFileData(*value.Data)
		if err != nil || uint64(len(data)) > *value.Size-*value.Offset {
			return invalid
		}
		digest := sha256.Sum256(data)
		if hex.EncodeToString(digest[:]) != *value.SHA256 {
			return invalid
		}
	case SandboxFileMkdir:
		if value.TransferID != nil || value.State != nil || value.Offset != nil || value.Size != nil || value.SHA256 != nil || value.Data != nil {
			return invalid
		}
	}
	return nil
}

func knownSandboxFileOperation(operation string) bool {
	switch operation {
	case SandboxFileUploadBegin, SandboxFileUploadChunk, SandboxFileUploadStatus, SandboxFileUploadCommit, SandboxFileUploadAbort, SandboxFileDownload, SandboxFileMkdir:
		return true
	}
	return false
}
