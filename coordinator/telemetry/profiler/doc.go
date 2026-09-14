// Package profiler owns prompt-free request profile construction, provider
// diagnostic validation and deterministic sampling. It persists through the
// independent profilequeue worker without owning request or billing state.
package profiler
