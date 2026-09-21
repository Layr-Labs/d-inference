package registry

// The catalog identity first receives native media, tools, paging and full
// context in this provider release. A mixed fleet must not route that identity
// to an older provider that accepts the architecture with different policies.
const qwen4RegistryModelID = "qwen3.8-flash-next"

// 0.9.5's signed app cannot resolve the native Qwen Metal resources.
const qwen4RegistryMinimumProviderVersion = "0.9.6"

func providerMeetsQwen4CatalogPolicyLocked(p *Provider, model string) bool {
	if model != qwen4RegistryModelID {
		return true
	}
	return p.Version != "" && CompareVersions(p.Version, qwen4RegistryMinimumProviderVersion) >= 0
}
