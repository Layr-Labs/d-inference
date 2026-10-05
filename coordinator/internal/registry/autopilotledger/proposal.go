package autopilotledger

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"

	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

// ProposalID identifies a distinct decision, not a cost time series. Sequence,
// time and benefit noise must not bypass ledger idempotency; unordered model
// sets share the same proposal identity.
func ProposalID(a autopilot.Action) string {
	identity := []any{"autopilot-shadow-proposal-v1", a.Node.ID, a.Node.State.Revision,
		a.Workload, a.Reason, a.Load, autopilot.SortedStrings(a.Unload),
		autopilot.ResidentIDs(a.Node.State), autopilot.SortedStrings(a.Node.State.SelectedModels)}
	body, _ := json.Marshal(identity) // only bounded strings and string sets
	digest := sha256.Sum256(body)
	return hex.EncodeToString(digest[:])
}
