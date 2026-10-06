package jsonvalue

// cloneJSONValue deep-copies a decoder-shaped value (objects, arrays, and
// immutable scalars). Non-JSON leaf types are shared, which is safe because
// the repair walk only ever rewrites map entries and array slots.
func Clone(v any) any {
	switch x := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(x))
		for key, value := range x {
			out[key] = Clone(value)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, value := range x {
			out[i] = Clone(value)
		}
		return out
	default:
		return v
	}
}
