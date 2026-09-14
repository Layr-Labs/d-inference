// Package toolpolicy owns tool-schema normalization and request tool-policy
// validation. It has no HTTP, registry, or server-state dependencies. Callers
// keep endpoint lowering, resolved-model compatibility, and response handling.
//
// NormalizeParsed preserves original tools for ValidateParsed; validation must
// inspect those original schemas before forwarding the normalized body.
package toolpolicy
