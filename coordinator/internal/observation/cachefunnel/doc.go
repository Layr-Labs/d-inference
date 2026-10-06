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
// Token sources. PromptTokens and RepeatedPrefixTokens are the planner's
// counts; PredictedTokens is routing's expectation for a selected holder;
// ReusedTokens, PrefillSavedTokens and ProviderPromptTokens are the completing
// provider's report. Reused tokens are the billing quantity (billed at the
// cache-read rate); prefill saved is the work actually skipped and never
// exceeds it. A ratio is single-source only when both terms come from the
// provider.
//
// Tier. A reported hit carries the tier it was restored from, so memory and
// SSD reuse are counted apart. The two tier counts sum to the hits because
// validated provider usage never reports a hit without a tier; the funnel
// itself does not enforce it.
//
// Conservation. Entered = Closed + InFlight, and Closed equals the sum of
// request counts over all reasons. The same holds for every token sum against
// the per-request records delivered to the Sink.
//
// Late evidence. A dispatch note that arrives after its request closed, and
// a completion that arrives after its request closed or after a hedged twin
// had completed, change no reason and no total. They are counted on their
// own (late completions also by hit tier, and their reuse by tier through the
// Sink), so for traffic inside the population the per-completion counters
// equal the funnel's plus the late ones. A late dispatch note that was its
// request's first leaves that request under a before-dispatch reason.
//
// Records and aggregates hold counts only: no prompt text, hashes, scopes,
// accounts, models or provider identifiers. Token sums are still
// prompt-derived, so PublicStatus, the form an unauthenticated reader gets,
// leaves them out.
package cachefunnel
