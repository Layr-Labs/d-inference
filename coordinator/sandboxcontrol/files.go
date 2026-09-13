package sandboxcontrol

import (
	"context"
	"encoding/base64"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

const (
	FileRelayTimeout              = 30 * time.Second
	maximumPendingFileRequests    = 32
	maximumPendingFilesPerAccount = 8
)

var (
	ErrFileRelayBusy    = errors.New("sandbox file relay is busy")
	ErrFileRelayTimeout = errors.New("sandbox file relay timed out")
	ErrFilesUnsupported = errors.New("sandbox host does not support files")
)

type FileRequest struct {
	Operation  string
	TransferID *string
	Path       *string
	Offset     *uint64
	Size       *uint64
	SHA256     *string
	Data       []byte
	Version    *string
}

type pendingSandboxFileRequest struct {
	accountID  string
	session    *sandboxhost.Session
	scope      protocol.SandboxScope
	operation  string
	transferID *string
	offset     *uint64
	size       *uint64
	version    *string
	result     chan *protocol.SandboxFileResultPayload
}

// FileOperation relays a bounded request without storing file bytes or file
// paths in the database. Upload state belongs to the guest's transfer ID. A
// timeout is an uncertain mutation outcome; consumers can inspect that ID.
func (c *Controller) FileOperation(ctx context.Context, accountID, sandboxID string, request FileRequest) (*protocol.SandboxFileResultPayload, error) {
	relayContext, cancel := context.WithTimeout(ctx, FileRelayTimeout)
	defer cancel()
	sandbox, err := c.store.GetSandbox(relayContext, accountID, sandboxID)
	if err != nil {
		return nil, err
	}
	if sandbox.State != store.SandboxStateReady || sandbox.TerminationRequested || !c.now().Before(sandbox.LeaseExpiresAt) {
		return nil, ErrSandboxNotReady
	}
	payload := protocol.SandboxFileOperationPayload{
		RequestID: uuid.NewString(), Scope: sandboxScope(sandbox), Operation: request.Operation,
		TransferID: request.TransferID, Path: request.Path, Offset: request.Offset,
		Size: request.Size, SHA256: request.SHA256, Version: request.Version,
	}
	if request.Data != nil {
		if len(request.Data) > protocol.SandboxMaximumFileChunkBytes {
			return nil, ErrInvalidRequest
		}
		encoded := base64.StdEncoding.EncodeToString(request.Data)
		payload.Data = &encoded
	}
	if protocol.ValidateSandboxFileOperation(&payload) != nil ||
		(request.Operation == protocol.SandboxFileUploadBegin && *request.Size > sandbox.WorkspaceBytes) {
		return nil, ErrInvalidRequest
	}
	if request.Offset != nil && *request.Offset > sandbox.WorkspaceBytes {
		return nil, ErrInvalidRequest
	}
	if request.Operation == protocol.SandboxFileUploadChunk && uint64(len(request.Data)) > sandbox.WorkspaceBytes-*request.Offset {
		return nil, ErrInvalidRequest
	}
	session, exists := c.hosts.Session(sandbox.HostID)
	if !exists {
		return nil, ErrHostUnavailable
	}
	if !session.Snapshot().Capabilities.SupportsFiles {
		return nil, ErrFilesUnsupported
	}
	pending := &pendingSandboxFileRequest{
		accountID: accountID, session: session, scope: payload.Scope, operation: request.Operation,
		transferID: request.TransferID, offset: request.Offset, size: request.Size, version: request.Version,
		result: make(chan *protocol.SandboxFileResultPayload, 1),
	}
	if err := c.addFileRequest(payload.RequestID, pending); err != nil {
		return nil, err
	}
	defer c.removeFileRequest(payload.RequestID)
	if err := session.Send(relayContext, protocol.SandboxTypeFileOperation, payload); err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if relayContext.Err() != nil {
			return nil, ErrFileRelayTimeout
		}
		return nil, ErrHostUnavailable
	}
	var result *protocol.SandboxFileResultPayload
	select {
	case result = <-pending.result:
	case <-session.Done():
		return nil, ErrHostUnavailable
	case <-c.done:
		return nil, ErrHostUnavailable
	case <-relayContext.Done():
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, ErrFileRelayTimeout
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if relayContext.Err() != nil {
		return nil, ErrFileRelayTimeout
	}
	// A result racing reconnect or lease renewal cannot be returned under the
	// previous authority, even if the host sent it before losing its session.
	select {
	case <-session.Done():
		return nil, ErrHostUnavailable
	default:
	}
	current, err := c.store.GetSandbox(relayContext, accountID, sandboxID)
	if err != nil {
		return nil, err
	}
	if sandboxScope(current) != pending.scope || current.State != store.SandboxStateReady ||
		current.TerminationRequested || !c.now().Before(current.LeaseExpiresAt) ||
		(result.Size != nil && *result.Size > current.WorkspaceBytes) {
		return nil, store.ErrSandboxConflict
	}
	return result, nil
}

func (c *Controller) addFileRequest(id string, pending *pendingSandboxFileRequest) error {
	c.fileMu.Lock()
	defer c.fileMu.Unlock()
	if len(c.pendingFileRequests) >= maximumPendingFileRequests {
		return ErrFileRelayBusy
	}
	accountCount := 0
	for _, request := range c.pendingFileRequests {
		if request.accountID == pending.accountID {
			accountCount++
		}
	}
	if accountCount >= maximumPendingFilesPerAccount {
		return ErrFileRelayBusy
	}
	if c.pendingFileRequests == nil {
		c.pendingFileRequests = make(map[string]*pendingSandboxFileRequest)
	}
	c.pendingFileRequests[id] = pending
	return nil
}

func (c *Controller) removeFileRequest(id string) {
	c.fileMu.Lock()
	delete(c.pendingFileRequests, id)
	c.fileMu.Unlock()
}

func (c *Controller) handleFileResult(session *sandboxhost.Session, result *protocol.SandboxFileResultPayload) error {
	if protocol.ValidateSandboxFileResult(result) != nil {
		return staleHostResultError(store.ErrSandboxConflict)
	}
	c.fileMu.Lock()
	defer c.fileMu.Unlock()
	pending := c.pendingFileRequests[result.RequestID]
	if pending == nil || pending.session != session || pending.scope != result.Scope || pending.operation != result.Operation ||
		((result.Success || result.TransferID != nil) && !sameOptionalString(pending.transferID, result.TransferID)) {
		return staleHostResultError(store.ErrSandboxConflict)
	}
	if result.Success && result.Operation == protocol.SandboxFileDownload {
		data, err := protocol.DecodeSandboxFileData(*result.Data)
		if err != nil || *result.Offset != *pending.offset || uint64(len(data)) > *pending.size ||
			(pending.version != nil && !sameOptionalString(pending.version, result.Version)) {
			return staleHostResultError(store.ErrSandboxConflict)
		}
	}
	select {
	case pending.result <- result:
		return nil
	default:
		return staleHostResultError(store.ErrSandboxConflict)
	}
}

func sameOptionalString(left, right *string) bool {
	if left == nil || right == nil {
		return left == nil && right == nil
	}
	return *left == *right
}
