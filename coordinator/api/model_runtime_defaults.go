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

// modelRuntimeDefaults remembers which allowlisted fields came from the caller
// and which were injected by the coordinator. The distinction matters when an
// alias switches concrete builds: caller values are immutable, while catalog
// defaults must follow the build that will actually serve the request.
type modelRuntimeDefaults struct {
	callerProvided [len(requestRuntimeDefaultKeys)]bool
	injected       [len(requestRuntimeDefaultKeys)]bool
}

func newModelRuntimeDefaults(callerParsed map[string]any) modelRuntimeDefaults {
	var defaults modelRuntimeDefaults
	for index, key := range requestRuntimeDefaultKeys {
		_, defaults.callerProvided[index] = callerParsed[key]
	}
	return defaults
}

// apply reconciles coordinator-owned fields with one concrete model's registry
// record. Repeated calls support alias fallback and retry: injected values are
// replaced or removed, while fields present in the original caller body are
// left untouched. Only non-empty string defaults from the narrow allowlist can
// enter the forwarded request.
func (defaults *modelRuntimeDefaults) apply(parsed map[string]any, runtimeParameters map[string]any) bool {
	changed := false
	for index, key := range requestRuntimeDefaultKeys {
		if defaults.callerProvided[index] {
			continue
		}

		value, hasDefault := runtimeParameters[key].(string)
		hasDefault = hasDefault && strings.TrimSpace(value) != ""

		if defaults.injected[index] {
			if !hasDefault {
				if _, exists := parsed[key]; exists {
					delete(parsed, key)
					changed = true
				}
				defaults.injected[index] = false
				continue
			}
			if current, exists := parsed[key]; !exists || current != value {
				parsed[key] = value
				changed = true
			}
			continue
		}

		if _, exists := parsed[key]; exists || !hasDefault {
			continue
		}
		parsed[key] = value
		defaults.injected[index] = true
		changed = true
	}
	return changed
}
