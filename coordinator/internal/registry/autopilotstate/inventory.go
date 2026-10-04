package autopilotstate

import (
	"slices"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Inventory owns cached advertisements and their observation-only classification.
// Its zero value has no cached models; the provider lock serializes mutations.
type Inventory struct {
	inventory  []protocol.ModelInfo
	onlyModels map[string]bool
}

// Count includes every observation-only classification, not just serving models.
func (s *Inventory) Count() int {
	if s == nil {
		return 0
	}
	return len(s.onlyModels)
}

// RegisterInventory validates observation metadata without granting ordinary
// serving permission. Ordinary advertisements win duplicate weight identities.
func (s *Inventory) RegisterInventory(serving, inventory []protocol.ModelInfo, state *protocol.ModelAutopilotState) []protocol.ModelInfo {
	s.inventory = nil
	if state != nil && state.Protocol == protocol.ModelAutopilotProtocol && state.Enabled && state.CachedOnly && len(inventory) <= 256 {
		for _, model := range inventory {
			if model.ID != "" && model.WeightHash != "" && slices.Contains(state.SelectedModels, model.ID) {
				s.inventory = append(s.inventory, model)
			}
		}
	}
	return s.ReplaceSelection(serving)
}

func (s *Inventory) ReplaceSelection(serving []protocol.ModelInfo) []protocol.ModelInfo {
	models := append([]protocol.ModelInfo(nil), serving...)
	seen := make(map[string]bool, len(serving))
	for _, model := range serving {
		seen[model.ID] = true
	}
	s.onlyModels = make(map[string]bool)
	for _, model := range s.inventory {
		if !seen[model.ID] {
			models = append(models, model)
			s.onlyModels[model.ID], seen[model.ID] = true, true
		}
	}
	return models
}

func (s *Inventory) ObserverOnly(model string) bool { return s != nil && s.onlyModels[model] }

func (s *State) OrdinaryAllowed(state *protocol.ModelAutopilotState, session, model string, now func() time.Time) bool {
	return s == nil || !s.ObserverOnly(model) || (s.control().activeNow(state, session, now) && Allows(state, model))
}

func (s *Inventory) Selected(models []protocol.ModelInfo, id string) bool {
	if id == "" || s.ObserverOnly(id) {
		return false
	}
	for _, model := range models {
		if model.ID == id {
			return true
		}
	}
	return false
}

func (s *Inventory) RefreshModel(model protocol.ModelInfo) {
	if s == nil {
		return
	}
	for i := range s.inventory {
		if s.inventory[i].ID == model.ID {
			s.inventory[i] = model
		}
	}
}

// PromoteSuccessor is called only after verification of the declared successor
// of an ordinary selection; a plain metadata refresh cannot promote inventory.
func (s *Inventory) PromoteSuccessor(model string) {
	if s != nil {
		delete(s.onlyModels, model)
	}
}

func (s *Inventory) DropRetired(drop map[string]struct{}) {
	if s == nil {
		return
	}
	inventory := s.inventory[:0]
	for _, model := range s.inventory {
		if _, removed := drop[model.ID]; !removed {
			inventory = append(inventory, model)
		}
	}
	s.inventory = inventory
}
