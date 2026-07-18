package registry

// PrefixCacheProtocolStatus is an aggregate, identity-free view of connected
// provider cache capability. V2ReadyModels counts advertised ready
// provider/model pairs, not unique models.
type PrefixCacheProtocolStatus struct {
	V0            int `json:"v0"`
	V1            int `json:"v1"`
	V2            int `json:"v2"`
	V2ReadyModels int `json:"v2_ready_models"`
}

func (r *Registry) PrefixCacheProtocolStatus() PrefixCacheProtocolStatus {
	var status PrefixCacheProtocolStatus
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
	})
	return status
}
