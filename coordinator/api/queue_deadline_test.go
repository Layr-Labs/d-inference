package api

// queue_deadline (routing-v2 P4): a request whose request-absolute
// first-content clock expires while it is still waiting in the coordinator
// queue was reported as first_chunk_timeout — indistinguishable in the
// rejection ledger from a dispatched provider that went silent. It now carries
// its own reason code, with the same retryable 429 + Retry-After.
