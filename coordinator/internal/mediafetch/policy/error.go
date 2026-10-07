package policy

import "fmt"

// Error is a typed resolution failure carrying the HTTP status + OpenAI-style
// error code to return to the consumer, a Public message, and a non-sensitive
// Internal diagnostic. Internal MUST NOT contain the request URL, host, query,
// fragment, credentials, or wrapped errors that may reproduce them: presigned
// media URLs commonly carry secrets and Error() may be logged by callers.
type Error struct {
	Status   int
	Code     string
	Public   string
	Internal string
}

func (e *Error) Error() string {
	if e.Internal != "" {
		return fmt.Sprintf("mediafetch: %s (%s): %s", e.Code, e.Public, e.Internal)
	}
	return fmt.Sprintf("mediafetch: %s (%s)", e.Code, e.Public)
}
