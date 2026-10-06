package inference

import (
	"net/http"

	prelude "github.com/eigeninference/d-inference/coordinator/internal/inference/prelude"
)

// NewPreludeParser binds request parsing to the owner's access policy.
func (s *Owner) NewPreludeParser() *prelude.Parser {
	return &prelude.Parser{KeyModelAllowed: s.keyModelAllowed}
}

func (s *Owner) parseInferencePrelude(w http.ResponseWriter, r *http.Request) (prelude.Result, bool) {
	return s.NewPreludeParser().Parse(w, r)
}
