package observation

import (
	"context"
	"encoding/json"
	"time"

	storagebudget "github.com/eigeninference/d-inference/coordinator/internal/appattest/storage"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// Record shares proof admission, including nested events emitted while an
// archived proof is in flight. Refused optional events never reach storage.
func Record(scope *storagebudget.Scope, st store.MachineInventoryStore, session, stage, outcome string, fields map[string]any) (bool, error) {
	release, ok := scope.Acquire()
	if !ok {
		return false, nil
	}
	defer release()
	raw, _ := json.Marshal(fields)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	err := st.RecordAppAttestEvent(ctx, store.AppAttestEvent{ID: uuid.NewString(), SessionID: session, At: time.Now().UTC(), Stage: stage, Outcome: outcome, Fields: raw})
	return true, err
}
