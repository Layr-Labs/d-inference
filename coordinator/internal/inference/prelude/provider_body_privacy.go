package prelude

// stripProviderCallerIdentity removes caller identification that is unnecessary
// for inference. This is deliberately shallow: identically named message, tool,
// schema and argument fields remain semantic input. Authentication, billing and
// cache scope come from trusted context, not these caller-controlled fields.
func stripProviderCallerIdentity(body map[string]any) {
	delete(body, "user")
	delete(body, "metadata")
}
