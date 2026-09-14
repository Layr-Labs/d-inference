package admission

const (
	// DefaultRequestedMaxTokens sizes routing and queue admission only; it is
	// neither a billing default nor a protocol limit.
	DefaultRequestedMaxTokens = 256

	// DefaultKVBytesPerToken is a per-token KV-cache size estimate used by
	// the free-memory admission gate.
	//
	// Measured on M4 Max (Qwen2.5-7B-4bit, prompt≈2330 + completion≈72):
	// 357,615 bytes/token (0.34 MB). Prior default of 0.5 MB was ~47%
	// too conservative — providers were being rejected for "no fit"
	// when they actually had room. Rounded up slightly to 400,000 to
	// leave headroom for larger models (70B class may be ~2x) without
	// re-running the gate per architecture. Refine per-model via
	// catalog metadata once more measurements exist.
	DefaultKVBytesPerToken = 400_000 // ~0.38 MB; covers 7-8B with slack
	// BytesPerGiB converts the memory reports and reserve constants to bytes.
	BytesPerGiB = 1 << 30
)
