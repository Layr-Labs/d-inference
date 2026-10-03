package api

// Benchmarks for the provider-side half of the streaming relay: one WebSocket
// frame (one token) from the read loop's decode through handleChunk (pending
// lookup, decrypt, boilerplate classification, channel hand-off). The fixture
// encrypts a Swift-shaped content delta with real X25519/NaCl keys and renders
// the frame in the Swift provider's sorted-key wire order.
