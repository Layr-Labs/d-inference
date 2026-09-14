package attempt

// Cancel causes: the bounded set of reasons the coordinator sends a WS cancel.
// A cancel is sent ONLY when the attempt's pending record still existed when
// it was abandoned — i.e. no provider terminal had been seen — so a provider
// error or a clean completion never produces one.
const (
	CancelCauseFirstChunkTimeout = "first_chunk_timeout"
	CancelCauseHedgeLoser        = "hedge_loser"
	CancelCauseClientGonePre     = "client_gone_pre"
	CancelCauseClientGonePost    = "client_gone_post"
	// CancelCauseStreamTimeout covers every other post-commit exit without a
	// terminal — the idle stream timeout in practice.
	CancelCauseStreamTimeout = "stream_timeout"
	CancelCauseOverflow      = "overflow"
	CancelCauseLateContent   = "late_content"
	// CancelCauseStrayChunk is a cancel triggered by a chunk for an id no
	// abandon path recorded (genuinely unknown, or predating a restart).
	CancelCauseStrayChunk = "stray_chunk"
)
