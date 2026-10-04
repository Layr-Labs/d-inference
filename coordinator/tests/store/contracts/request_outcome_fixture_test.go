package store_test

import (
	"encoding/json"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func cloneRequestOutcomeFixture(r store.RequestOutcomeRecord) store.RequestOutcomeRecord {
	b, _ := json.Marshal(r)
	var out store.RequestOutcomeRecord
	_ = json.Unmarshal(b, &out)
	return out
}
