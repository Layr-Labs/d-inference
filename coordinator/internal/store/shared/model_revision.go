package shared

import "github.com/eigeninference/d-inference/coordinator/store"

func SameModelVersionFiles(a, b []store.ModelVersionFile) bool {
	if len(a) != len(b) {
		return false
	}
	byPath := make(map[string]store.ModelVersionFile, len(a))
	for _, f := range a {
		byPath[f.Path] = f
	}
	for _, f := range b {
		old, ok := byPath[f.Path]
		if !ok || old.SizeBytes != f.SizeBytes || old.SHA256 != f.SHA256 || old.Role != f.Role {
			return false
		}
		delete(byPath, f.Path)
	}
	return len(byPath) == 0
}
