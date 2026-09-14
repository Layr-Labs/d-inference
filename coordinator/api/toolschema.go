package api

import "github.com/eigeninference/d-inference/coordinator/inference/toolpolicy"

// NormalizeToolSchemas returns a request with render-safe tool schemas.
// Deprecated: use toolpolicy.NormalizeBytes.
func NormalizeToolSchemas(body []byte) []byte { return toolpolicy.NormalizeBytes(body) }
