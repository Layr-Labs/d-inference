package api

// This file holds the consumer-side "use my own machine, for free" (self-route)
// helpers: how the opt-in is resolved from the authenticated request, and how
// pre-flight eligibility maps to precise, no-fallback error responses. The
// routing/billing wiring that consumes these lives in consumer.go (dispatch)
// and provider.go (settlement); the owner filter and trust relaxation live in
// the registry scheduler.
