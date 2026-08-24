package api

import "strings"

// requestRuntimeDefaultKeys is the catalog-owned subset of runtime_parameters
// that belongs on the forwarded OpenAI request. Keep this allowlist narrow:
// registry metadata may also carry provider/load controls that must never be
// copied into a consumer body.
var requestRuntimeDefaultKeys = [...]string{
	"reasoning_parser",
	"tool_call_parser",
}

// injectModelRuntimeDefaults fills omitted request fields from the model's
// registry record. Explicit consumer values always win. Only non-empty string
// defaults are forwarded so malformed admin metadata cannot turn an otherwise
// valid inference request into a provider-side JSON decode failure.
func injectModelRuntimeDefaults(parsed map[string]any, runtimeParameters map[string]any) bool {
	changed := false
	for _, key := range requestRuntimeDefaultKeys {
		if _, exists := parsed[key]; exists {
			continue
		}
		value, ok := runtimeParameters[key].(string)
		if !ok || strings.TrimSpace(value) == "" {
			continue
		}
		parsed[key] = value
		changed = true
	}
	return changed
}
