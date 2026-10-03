package api

// Streaming-relay coalescing primitives shared by the chat, Responses and
// generic-endpoint relays. When a relay wakes on one provider chunk, chunks
// that are ALREADY queued behind it are folded into the same write + Flush
// instead of costing one syscall each. The drain never waits for more chunks,
// so it adds no latency: a lone chunk is still flushed immediately.
