package store

// Unwrapper is implemented by Store decorators (CachedStore) so optional,
// backend-only capabilities remain discoverable through the wrapper. A
// decorator embeds the static Store method set, so a plain type assertion on
// it can never see methods the concrete backend adds beyond Store.
type Unwrapper interface {
	Unwrap() Store
}

// As reports whether s -- or any Store it wraps -- implements T, returning the
// innermost value that does. Use it instead of a direct type assertion when
// probing for an optional capability (e.g. paged verification-job listing or
// durable push budgets) so the probe keeps working once main.go wraps the
// backend in CachedStore. s may be any Store slice (a narrow sub-interface
// is fine); nil yields false.
func As[T any](s any) (T, bool) {
	var zero T
	for s != nil {
		if t, ok := s.(T); ok {
			return t, true
		}
		u, ok := s.(Unwrapper)
		if !ok {
			return zero, false
		}
		s = u.Unwrap()
	}
	return zero, false
}
