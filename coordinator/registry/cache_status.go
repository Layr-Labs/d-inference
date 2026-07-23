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
		ByState:          zeroBuckets[int](prefixCacheStatusStates),
		ByReason:         zeroBuckets[int](prefixCacheStatusReasons),
		ByBackend:        zeroBuckets[int](prefixCacheStatusBackends),
		ByReplayStrategy: zeroBuckets[int](prefixCacheReplayStrategies),
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

// zeroBuckets pre-fills a fixed metric vocabulary so gauges report explicit
// zeros instead of omitting quiet buckets.
func zeroBuckets[N int | uint64](values []string) map[string]N {
	result := make(map[string]N, len(values))
	for _, value := range values {
		result[value] = 0
	}
	return result
}

// loadedProviderModelsLocked counts models occupying memory for telemetry.
// This is deliberately wider than the scheduler's warm-for-routing detection
// ("running"/"idle" only): a reloading or crashed slot still holds a model
// whose cache-eligibility status operators need attributed. Do not unify the
// two state sets.
func loadedProviderModelsLocked(provider *Provider) map[string]struct{} {
	if provider.BackendCapacity != nil {
		loaded := make(map[string]struct{}, len(provider.BackendCapacity.Slots))
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
	loaded := make(map[string]struct{}, len(provider.WarmModels)+1)
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
