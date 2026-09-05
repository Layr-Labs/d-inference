package store

// Deep-copy helpers for the values CachedStore hands out. The cached value is
// the canonical copy; callers (e.g. the admin runtime_parameters PATCH, which
// writes into rec.RuntimeParameters before upserting) must never be able to
// reach it through a returned pointer.

func cloneUser(u *User) *User {
	if u == nil {
		return nil
	}
	cp := *u
	cp.PlatformFeePercent = cloneInt64Ptr(u.PlatformFeePercent)
	return &cp
}

func cloneModelRegistryRecord(rec *ModelRegistryRecord) *ModelRegistryRecord {
	if rec == nil {
		return nil
	}
	cp := &ModelRegistryRecord{ModelRegistryEntry: cloneRegistryEntryForCache(&rec.ModelRegistryEntry)}
	if rec.ActiveVersion != nil {
		v := cloneModelVersionForCache(rec.ActiveVersion)
		cp.ActiveVersion = &v
	}
	if rec.Files != nil {
		cp.Files = make([]ModelVersionFile, len(rec.Files))
		copy(cp.Files, rec.Files)
	}
	return cp
}

// cloneRegistryEntryForCache mirrors cloneModelRegistryEntry but copies the
// JSON-shaped maps structurally instead of through a JSON round-trip: this
// runs 3-4 times per inference request, and a structural copy preserves the
// exact dynamic types the inner store produced (nil stays nil, numbers keep
// their kind) rather than normalizing them.
func cloneRegistryEntryForCache(entry *ModelRegistryEntry) ModelRegistryEntry {
	cp := *entry
	cp.Capabilities = cloneStrings(entry.Capabilities)
	cp.RequiredProviderCapabilities = cloneStrings(entry.RequiredProviderCapabilities)
	cp.RuntimeParameters = cloneJSONMap(entry.RuntimeParameters)
	cp.Metadata = cloneJSONMap(entry.Metadata)
	return cp
}

func cloneModelVersionForCache(version *ModelVersion) ModelVersion {
	cp := *version
	cp.PromotedAt = cloneTimePtr(version.PromotedAt)
	cp.HuggingFaceArtifact = cloneHuggingFaceArtifact(version.HuggingFaceArtifact)
	cp.Metadata = cloneJSONMap(version.Metadata)
	return cp
}

func cloneStrings(s []string) []string {
	if s == nil {
		return nil
	}
	out := make([]string, len(s))
	copy(out, s)
	return out
}

// cloneJSONMap deep-copies a map produced by JSON decoding (or by the memory
// store's JSON-round-trip clone): nested map[string]any and []any are copied
// recursively; every other value is an immutable scalar and is shared.
func cloneJSONMap(m map[string]any) map[string]any {
	if m == nil {
		return nil
	}
	out := make(map[string]any, len(m))
	for k, v := range m {
		out[k] = cloneJSONValue(v)
	}
	return out
}

func cloneJSONValue(v any) any {
	switch t := v.(type) {
	case map[string]any:
		return cloneJSONMap(t)
	case []any:
		out := make([]any, len(t))
		for i := range t {
			out[i] = cloneJSONValue(t[i])
		}
		return out
	case []string:
		return cloneStrings(t)
	default:
		return v
	}
}
