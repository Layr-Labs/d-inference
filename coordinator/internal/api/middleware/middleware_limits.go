package middleware

import (
	_ "embed"
)

// maxRequestBodyBytes is the global ceiling bodyLimitMiddleware applies to every
// request body so no endpoint can be OOM'd by an unbounded POST. It's a coarse
// outer bound that clears every legitimate body with headroom; the hot paths
// self-cap tighter on top (the plaintext-inference path at 16 MiB, sized to the
// provider WS frame budget — see maxInferenceBodyBytes).
const maxRequestBodyBytes = 64 << 20
