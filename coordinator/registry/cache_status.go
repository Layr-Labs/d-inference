package registry

// PrefixCacheProtocolStatus is an aggregate, identity-free view of connected
// provider cache capability. V2ReadyModels counts advertised ready
// provider/model pairs, not unique models.
type PrefixCacheProtocolStatus struct {
	V0                     int            `json:"v0"`
	V1                     int            `json:"v1"`
	V2                     int            `json:"v2"`
	V2ReadyModels          int            `json:"v2_ready_models"`
	LoadedModels           int            `json:"loaded_models"`
	ReportedLoadedModels   int            `json:"reported_loaded_models"`
	UnreportedLoadedModels int            `json:"unreported_loaded_models"`
	ExcludedModels         int            `json:"excluded_models"`
	ByState                map[string]int `json:"by_state"`
	ByReason               map[string]int `json:"by_reason"`
	ByBackend              map[string]int `json:"by_backend"`
	ByReplayStrategy       map[string]int `json:"by_replay_strategy"`
}

func (r *Registry) PrefixCacheProtocolStatus() PrefixCacheProtocolStatus {
	status := PrefixCacheProtocolStatus{
		ByState:          zeroIntBuckets(prefixCacheStatusStates),
		ByReason:         zeroIntBuckets(prefixCacheStatusReasons),
		ByBackend:        zeroIntBuckets(prefixCacheStatusBackends),
		ByReplayStrategy: zeroIntBuckets(prefixCacheReplayStrategies),
	}
	if r == nil {
		return status
	}
	r.ForEachProvider(func(provider *Provider) {
		provider.mu.Lock()
		defer provider.mu.Unlock()
		switch provider.PrefixCacheProtocol {
		case 0:
			status.V0++
		case 1:
			status.V1++
		default:
			status.V2++
			for _, capability := range provider.PrefixCacheV2Models {
				if capability.Enabled && capability.Ready {
					status.V2ReadyModels++
				}
			}
		}
		loaded := loadedProviderModelsLocked(provider)
		for modelID, modelStatus := range provider.PrefixCacheStatuses {
			loaded[modelID] = struct{}{}
			status.ReportedLoadedModels++
			status.ByState[modelStatus.State]++
			status.ByReason[modelStatus.Reason]++
			status.ByBackend[modelStatus.Backend]++
			status.ByReplayStrategy[modelStatus.ReplayStrategy]++
			if modelStatus.State != "ready" {
				status.ExcludedModels++
			}
		}
		if provider.PrefixCacheStatusReported {
			for modelID := range loaded {
				if _, reported := provider.PrefixCacheStatuses[modelID]; !reported {
					status.UnreportedLoadedModels++
				}
			}
		} else {
			status.UnreportedLoadedModels += len(loaded)
		}
		status.LoadedModels += len(loaded)
	})
	return status
}

func zeroIntBuckets(values []string) map[string]int {
	result := make(map[string]int, len(values))
	for _, value := range values {
		result[value] = 0
	}
	return result
}

func loadedProviderModelsLocked(provider *Provider) map[string]struct{} {
	loaded := make(map[string]struct{})
	if provider.BackendCapacity != nil {
		for _, slot := range provider.BackendCapacity.Slots {
			if slot.Model == "" {
				continue
			}
			switch slot.State {
			case "idle", "running", "reloading", "crashed":
				loaded[slot.Model] = struct{}{}
			}
		}
		return loaded
	}
	for _, modelID := range provider.WarmModels {
		if modelID != "" {
			loaded[modelID] = struct{}{}
		}
	}
	if provider.CurrentModel != "" {
		loaded[provider.CurrentModel] = struct{}{}
	}
	return loaded
}
