package memory

import (
	"encoding/json"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func cloneRequestOutcome(r store.RequestOutcomeRecord) store.RequestOutcomeRecord {
	// All fields are bounded scalars and a bounded attempt slice. Clone pointers too.
	b, _ := json.Marshal(r)
	var out store.RequestOutcomeRecord
	_ = json.Unmarshal(b, &out)
	return out
}
