package api

// Shared inference-completion drain for the background prober.
//
// The provider read loop (provider.go) pushes SSE chunks onto pr.ChunkCh, then
// on success sets pr.SESignature / pr.ResponseHash, sends the usage on
// pr.CompleteCh, and closes ChunkCh + CompleteCh. On failure it sends on
// pr.ErrorCh and closes all three channels. The consumer HTTP path drains inline
// (consumer.go) because it must refund a reservation and write a response; the
// prober has neither, so it only needs the assembled assistant text plus the
// completion metadata.

import (
	"context"
	"errors"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// awaitCompletion drains pr to a finished inference and returns the assembled
// assistant text along with usage and SE-signature metadata, or an error if the
// provider failed or the context expired. It performs NO billing/refund and
// writes NO HTTP response.
//
// Ordering guarantee (provider.go): SESignature/ResponseHash are set on pr before
// usage is sent on CompleteCh, so reading CompleteCh makes them safe to read.
func (s *Server) awaitCompletion(ctx context.Context, pr *registry.PendingRequest) (text string, usage protocol.UsageInfo, seSig, respHash string, err error) {
	var chunks []string
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
						return "", protocol.UsageInfo{}, "", "", errors.New(errMsg.Error)
					}
				default:
				}
				select {
				case u, ok := <-pr.CompleteCh:
					if !ok {
						return "", protocol.UsageInfo{}, "", "", errors.New("provider ended without completion")
					}
					return extractMessage(chunks).Content, u, pr.SESignature, pr.ResponseHash, nil
				case <-ctx.Done():
					return "", protocol.UsageInfo{}, "", "", ctx.Err()
				}
			}
			chunks = append(chunks, chunk)

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			return "", protocol.UsageInfo{}, "", "", errors.New(errMsg.Error)

		case <-ctx.Done():
			return "", protocol.UsageInfo{}, "", "", ctx.Err()
		}
	}
}
