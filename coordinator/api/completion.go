package api

// Shared inference-completion drain logic.
//
// The provider read loop (provider.go) pushes SSE chunks onto pr.ChunkCh, then
// on success sets pr.SESignature / pr.ResponseHash, sends the usage on
// pr.CompleteCh, and closes ChunkCh + CompleteCh. On failure it sends on
// pr.ErrorCh and closes all three channels. Every consumer of a PendingRequest
// (the non-streaming HTTP handler, and the background prober) needs the same
// drain sequence: read chunks until ChunkCh closes, then resolve the terminal
// state. This file factors that sequence out so it lives in exactly one place.

import (
	"context"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// completionErrorKind classifies how a drain failed so callers can map it to a
// consumer-facing status code, ledger refund reference, and log line without
// re-deriving the cause.
type completionErrorKind int

const (
	// completionProviderError: the provider sent an explicit inference error.
	completionProviderError completionErrorKind = iota
	// completionIncomplete: the provider closed the stream without usage.
	completionIncomplete
	// completionTimeout: the context deadline fired before completion.
	completionTimeout
)

// completionError is the typed failure returned by drainCompletion. It carries
// the consumer-facing HTTP status and a stable reference suffix so the HTTP
// handler can refund the reservation with the same reference strings it used
// before this helper existed (behavior-preserving). The prober ignores the
// status/reference and only cares that the drain failed.
type completionError struct {
	Kind          completionErrorKind
	StatusCode    int    // consumer-facing HTTP status
	Message       string // consumer-facing error message
	RefSuffix     string // ledger refund reference, e.g. "provider_error:"
	ProviderError string // raw provider error string, if any
}

func (e *completionError) Error() string {
	if e.Message != "" {
		return e.Message
	}
	return e.ProviderError
}

// completionResult holds everything a drain produced on success. Chunks are the
// raw SSE/data frames in arrival order (with any pre-read firstChunk prepended)
// so the HTTP handler can keep its complete-object passthrough vs. SSE
// reconstruction branching. Usage / SESignature / ResponseHash come from the
// inference_complete message.
type completionResult struct {
	Chunks       []string
	Usage        protocol.UsageInfo
	SESignature  string
	ResponseHash string
}

// drainCompletion consumes pr's channels until the provider finishes, returning
// the collected chunks and completion metadata, or a typed completionError. It
// performs NO billing/refund and writes NO HTTP response — those side effects
// stay with the caller, because the consumer path refunds a reservation while
// the prober has none. firstChunk, if non-empty, is treated as the first chunk
// already read off the wire by the caller.
//
// Ordering guarantee (provider.go): SESignature/ResponseHash are set on pr
// before usage is sent on CompleteCh, so reading CompleteCh makes them safe to
// read.
func (s *Server) drainCompletion(ctx context.Context, pr *registry.PendingRequest, firstChunk string) (completionResult, *completionError) {
	var chunks []string
	if firstChunk != "" {
		chunks = append(chunks, firstChunk)
	}

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
				// ChunkCh closed — resolve the terminal state. The provider
				// handler sends on ErrorCh (failure) or CompleteCh (success)
				// before closing ChunkCh, so a non-blocking ErrorCh check wins
				// the race when present.
				select {
				case errMsg, ok := <-pr.ErrorCh:
					if ok && errMsg.Error != "" {
						return completionResult{}, providerErrorFromMsg(errMsg, pr.RequestID)
					}
				default:
				}
				select {
				case usage, ok := <-pr.CompleteCh:
					if !ok {
						return completionResult{}, &completionError{
							Kind:       completionIncomplete,
							StatusCode: http.StatusBadGateway,
							Message:    "provider ended without completion",
							RefSuffix:  "provider_incomplete:" + pr.RequestID,
						}
					}
					return completionResult{
						Chunks:       chunks,
						Usage:        usage,
						SESignature:  pr.SESignature,
						ResponseHash: pr.ResponseHash,
					}, nil
				case <-ctx.Done():
					return completionResult{}, &completionError{
						Kind:       completionTimeout,
						StatusCode: http.StatusGatewayTimeout,
						Message:    "timed out waiting for usage info",
						RefSuffix:  "provider_timeout:" + pr.RequestID,
					}
				}
			}
			chunks = append(chunks, chunk)

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			return completionResult{}, providerErrorFromMsg(errMsg, pr.RequestID)

		case <-ctx.Done():
			return completionResult{}, &completionError{
				Kind:       completionTimeout,
				StatusCode: http.StatusGatewayTimeout,
				Message:    "request timed out",
				RefSuffix:  "provider_timeout:" + pr.RequestID,
			}
		}
	}
}

// providerErrorFromMsg builds a completionError from a provider inference error,
// defaulting a missing status code to 502 exactly as the HTTP handler did.
func providerErrorFromMsg(errMsg protocol.InferenceErrorMessage, requestID string) *completionError {
	statusCode := errMsg.StatusCode
	if statusCode == 0 {
		statusCode = http.StatusBadGateway
	}
	return &completionError{
		Kind:          completionProviderError,
		StatusCode:    statusCode,
		Message:       errMsg.Error,
		RefSuffix:     "provider_error:" + requestID,
		ProviderError: errMsg.Error,
	}
}

// awaitCompletion drains pr to a finished inference and returns the assembled
// assistant text along with usage and SE-signature metadata. It is the
// text-oriented wrapper used by the prober (which doesn't care about raw SSE
// framing); the consumer HTTP path uses drainCompletion directly so it can keep
// its complete-object passthrough behavior. Behavior-preserving: assembled text
// uses the same extractMessage reconstruction the consumer path applies.
func (s *Server) awaitCompletion(ctx context.Context, pr *registry.PendingRequest) (text string, usage protocol.UsageInfo, seSig, respHash string, err error) {
	res, cerr := s.drainCompletion(ctx, pr, "")
	if cerr != nil {
		return "", protocol.UsageInfo{}, "", "", cerr
	}
	msg := extractMessage(res.Chunks)
	return msg.Content, res.Usage, res.SESignature, res.ResponseHash, nil
}
