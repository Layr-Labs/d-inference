// Package cachefunnel accounts for where prompt-cache reuse is lost, one
// request at a time, so that the totals can be reconciled with raw
// per-request records.
//
// Population. A request enters the funnel when it is a text request (no
// image, audio or video part) for a catalog model while cache routing is on.
// Membership is decided once, before planning, and never revised by anything
// that happens to the request afterwards.
//
// Terminal reason. Every request in the population ends in exactly one Reason.
// Reasons follow the request lifecycle (planning, dispatch, routing, provider
// outcome); a request is charged to the first stage that ruled reuse out. A
// provider-reported hit overrides every loss reason, because it is the one
// outcome that shows reuse actually happened. Cancellation and failure claim
// only the requests no earlier stage had already ruled out.
//
// Attempts. Retries and hedges add attempts to one request, never requests.
// The request is classified by the attempt that completed; when none
// completed, by the attempt dispatched last. A recorded completion is proof
// of dispatch, whichever of the two was recorded first.
//
// Unknown is not zero. A token quantity the coordinator could not observe is
// counted in the matching "unknown" request count and contributes nothing to
// the token sum.
//
// Conservation. Entered = Closed + InFlight, and Closed equals the sum of
// request counts over all reasons. The same holds for every token sum against
// the per-request records delivered to the Sink.
//
// Records and aggregates hold counts only: no prompt text, hashes, scopes,
// accounts, models or provider identifiers. Token sums are still
// prompt-derived, so PublicStatus, the form an unauthenticated reader gets,
// leaves them out.
package cachefunnel
