package api

// Typed terminal-cause health classification (the generation-deadline incident
// fix): the provider's flat safety deadline used to arrive as a generic 500,
// so the coordinator recorded a provider job failure and struck every health
// breaker for a PLATFORM policy ~178K times/week. These tests pin, for every
// value of the closed terminal_cause vocabulary (plus absent and unknown),
// exactly which failure recorders and breakers fire — through the REAL glue:
// handleInferenceError (reputation + load cooldown) and noteInferenceError
// (shape breaker, node-health breaker, stable-identity ejection, capacity
// cooldown), the same two funnels the incident report warns must be gated
// together.
