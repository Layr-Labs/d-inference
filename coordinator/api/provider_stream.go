package api

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type providerStreamEnd uint8

const (
	providerStreamClosed providerStreamEnd = iota
	providerStreamFailed
	providerStreamTimedOut
	providerStreamClientGone
)

// relayProviderStream owns channel arbitration and bounded coalescing for every
// streaming endpoint. Callers own wire encoding, idle-timer resets, settlement,
// and terminal events. Queued content is flushed before a close or error is
// returned; a close still requires the caller to check for a trailing ErrorCh
// message before interpreting completion.
func relayProviderStream(
	ctx context.Context,
	pr *registry.PendingRequest,
	timer *time.Timer,
	relayChunk func(registry.ProviderChunk),
	flush func(),
) (providerStreamEnd, protocol.InferenceErrorMessage) {
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
				return providerStreamClosed, protocol.InferenceErrorMessage{}
			}
			relayChunk(chunk)
			closed := drainQueuedChunks(pr.ChunkCh, maxCoalescedChunks-1, relayChunk)
			flush()
			if closed {
				return providerStreamClosed, protocol.InferenceErrorMessage{}
			}
		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			// Error delivery precedes channel closure. Preserve every chunk
			// already queued ahead of the error before emitting its terminal.
			drainQueuedChunks(pr.ChunkCh, cap(pr.ChunkCh), relayChunk)
			flush()
			return providerStreamFailed, errMsg
		case <-timer.C:
			return providerStreamTimedOut, protocol.InferenceErrorMessage{}
		case <-ctx.Done():
			return providerStreamClientGone, protocol.InferenceErrorMessage{}
		}
	}
}
