package api

// Per-request dispatch state machine shared by consumer inference routes.
// Attempts retain the original first-content clock, fail over without exposing
// provider preambles, and commit exactly one content stream or valid terminal.
// first_content_retry.go carries evidence refresh and queue policy;
// dispatch_plan_wiring.go carries retained-plan and quote/hedge integration.
