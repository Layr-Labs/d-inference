package retry

// envJinjaTerminalReject is the kill switch for the deterministic
// template-render rejection stop (E4, 2026-07-15 platform errors deep dive).
// A provider error_reason of jinja_channel_tags / jinja_null_bridge /
// jinja_template means the model's chat template could not render the
// request's tool schemas or message history — the same body renders the same
// way on every provider, so failing over is pure waste (prod: 1.57 dispatch
// rows per jinja request, observed up to 17 attempts, 0% eventual success).
// Default true: the ladder stops on the FIRST jinja_* rejection at any
// attempt and surfaces one 422 model_capability invalid_request_error. Set
// =false to restore the legacy fail-over-on-500 behavior. Read live (not a
// Server field) following the envTTFTTerminalReject pattern, so it stays
// confined to this file and is overridable in tests via t.Setenv.
const TemplateRejectEnv = "EIGENINFERENCE_JINJA_TERMINAL_REJECT"

// jinjaTerminalRejectEnabled reports whether a jinja_* provider rejection
// terminates the dispatch ladder. Default true.
func TemplateRejectEnabled() bool {
	return EnvEnabledDefaultTrue(TemplateRejectEnv)
}

// jinjaTerminalRejectMessage is the OpenAI-style error body surfaced for a
// latched template-render failure — a curated model_capability message
// instead of the provider's raw Jinja backtrace (which names filters and
// template internals no API consumer can act on).
const TemplateRejectMessage = "the request's tool schemas or message history cannot be rendered by this model's chat template; simplify the tool parameter schemas or message structure, or use a different model"
