package inference

import (
	"net/http"
	"time"
)

func (s *Owner) requestFirstContentDeadline(r *http.Request, publicModel, model string, tokens int) (time.Duration, error) {
	return s.firstContentPolicy.Deadline(r, publicModel, model, tokens)
}

func (s *Owner) firstContentHedgeDelay(model string, tokens int, deadline time.Duration) time.Duration {
	return s.firstContentPolicy.HedgeDelay(model, tokens, deadline)
}
