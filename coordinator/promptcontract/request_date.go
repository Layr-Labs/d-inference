package promptcontract

import "time"

// RequestDateField carries a coordinator-owned date through endpoint lowering,
// planning and sealed dispatch. It is never taken from consumer input.
const RequestDateField = "_darkbloom_prompt_date"

// SetRequestDate pins date-dependent templates to the request's UTC calendar
// date, including every retry and model fallback. The actual rendered tokens
// change on the next day; the cache needs no separate daily invalidation.
func SetRequestDate(body map[string]any, receivedAt time.Time) {
	body[RequestDateField] = receivedAt.UTC().Format(time.DateOnly)
}
