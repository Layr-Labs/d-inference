package toolpolicy

// Mode is the caller's tool-choice policy after validation.
type Mode string

const (
	Auto     Mode = "auto"
	None     Mode = "none"
	Required Mode = "required"
	Named    Mode = "named"
)

// Policy carries the validated tool-choice and parallel-call preferences.
// Name is set for Named choices; Parallel defaults to true when omitted.
type Policy struct {
	Mode     Mode
	Name     string
	Parallel bool
}

// ErrorKind distinguishes malformed requests from schemas that cannot be
// enforced by the provider's constrained decoder. HTTP adapters choose statuses.
type ErrorKind uint8

const (
	InvalidRequest ErrorKind = iota + 1
	UnsupportedSchema
)

// ValidationError describes a tool-policy rejection without an HTTP dependency.
type ValidationError struct {
	Kind    ErrorKind
	Message string
	Param   string
}

func (e *ValidationError) Error() string { return e.Message }

func invalidToolConstraint(message, param string) error {
	return &ValidationError{Kind: InvalidRequest, Message: message, Param: param}
}

func unsupportedToolConstraint(message string) error {
	return &ValidationError{Kind: UnsupportedSchema, Message: message, Param: "tools"}
}

// RequiresInferenceConstraint reports whether the mode needs provider-side
// inference-time tool_choice enforcement (a sampler grammar for Gemma or
// withheld parse/schema validation for Qwen).
// `none` is deliberately excluded: it is honored by hiding tools from the
// rendered prompt and rejecting any call the model emits anyway after
// generation, so it must not be fenced to the constrained provider pool.
func (m Mode) RequiresInferenceConstraint() bool {
	return m == Required || m == Named
}
