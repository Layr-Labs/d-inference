package api

import "github.com/eigeninference/d-inference/coordinator/store"

// openRouterAliasUsesConcreteSource preserves the legacy meaning of an empty
// source_kind: OpenRouter aliases created before source kinds were persisted
// always cloned a standard alias.
func openRouterAliasUsesConcreteSource(alias store.ModelAlias) bool {
	return alias.SourceKind == store.ModelAliasSourceConcrete
}

func standardAliasCoversBuild(alias store.ModelAlias, buildID string) bool {
	if !alias.Active || alias.OpenRouterOnly || buildID == "" {
		return false
	}
	if alias.DesiredBuild == buildID || alias.PreviousBuild == buildID {
		return true
	}
	for _, retired := range alias.RetiredBuilds {
		if retired == buildID {
			return true
		}
	}
	return false
}

func standardAliasCoveringBuild(aliases []store.ModelAlias, buildID string) (string, bool) {
	for _, alias := range aliases {
		if standardAliasCoversBuild(alias, buildID) {
			return alias.AliasID, true
		}
	}
	return "", false
}

func concreteOpenRouterAliasUsingBuild(aliases []store.ModelAlias, builds map[string]struct{}) (store.ModelAlias, bool) {
	for _, alias := range aliases {
		if !alias.Active || !alias.OpenRouterOnly || !openRouterAliasUsesConcreteSource(alias) {
			continue
		}
		if _, covered := builds[alias.SourceModel]; covered {
			return alias, true
		}
	}
	return store.ModelAlias{}, false
}
