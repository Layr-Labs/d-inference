package extract

import (
	"go/types"
	"strings"
)

// This file answers a question the field walk cannot: which of a service's
// in-memory types are *state* rather than values passed around.
//
// The map's weak spot is the package-wide default. `deps.packageDefault` exists
// so a package's incidental fields do not each need a line in the overlay, but it
// is indiscriminate: a genuinely new stateful holder — a cache, a queue, a
// counter table someone adds to coordinator/registry — folds into whatever node
// the package defaults to and never appears as a boundary of its own. Nobody
// gets a build failure, and the picture quietly understates the system.
//
// The criterion below is derived, not curated, and it is a language-level fact:
// a struct whose fields include a mutex, an atomic, or a channel is a type
// designed to be mutated from more than one goroutine. That is state someone has
// to name. A plain struct of scalars, slices and strings is a value — a DTO, a
// plan, a snapshot — and mapping every one of those would bury the map in noise
// (removing the registry default alone leaves 601 unmapped reachable fields, and
// the large majority are exactly that shape).
//
// So: reach a struct's field from an endpoint, and if that struct is concurrent
// state that only a package default explains, it is drift until the overlay
// either gives it a node or says "@skip" on purpose.

// concurrentField reports the first field that makes a struct concurrent state,
// as (field name, type string). Embedded structs from the same service are
// searched too, because an embedded mutex is the standard idiom.
func concurrentField(named *types.Named, module string) (string, string, bool) {
	return concurrentFieldAt(named, module, 0, map[string]bool{})
}

// embedDepth bounds the embedded-struct search. Real embedding chains are one or
// two deep; the bound plus the seen set makes the walk terminate on recursive
// types.
const embedDepth = 4

func concurrentFieldAt(named *types.Named, module string, depth int, seen map[string]bool) (string, string, bool) {
	if named == nil || named.Obj().Pkg() == nil || depth > embedDepth {
		return "", "", false
	}
	key := named.Obj().Pkg().Path() + ":" + named.Obj().Name()
	if seen[key] {
		return "", "", false
	}
	seen[key] = true
	st, ok := named.Underlying().(*types.Struct)
	if !ok {
		return "", "", false
	}
	for i := 0; i < st.NumFields(); i++ {
		field := st.Field(i)
		if isConcurrent(field.Type()) {
			return field.Name(), shortType(field.Type()), true
		}
	}
	// Embedded state counts as this struct's state: `type X struct { mu sync.Mutex
	// ... }` embedded in Y makes Y concurrent too.
	for i := 0; i < st.NumFields(); i++ {
		field := st.Field(i)
		if !field.Embedded() {
			continue
		}
		inner := namedOf(field.Type())
		if inner == nil || inner.Obj().Pkg() == nil {
			continue
		}
		if module != "" && !strings.HasPrefix(inner.Obj().Pkg().Path(), module) {
			continue
		}
		if name, typ, ok := concurrentFieldAt(inner, module, depth+1, seen); ok {
			return field.Name() + "." + name, typ, true
		}
	}
	return "", "", false
}

// isConcurrent reports whether a field's type is a concurrency primitive: a
// channel, a sync lock or map, or anything from sync/atomic. Pointers are
// unwrapped once — `mu *sync.Mutex` is still a lock.
func isConcurrent(t types.Type) bool {
	t = types.Unalias(t)
	if ptr, ok := t.(*types.Pointer); ok {
		t = types.Unalias(ptr.Elem())
	}
	if _, ok := t.Underlying().(*types.Chan); ok {
		return true
	}
	named, ok := t.(*types.Named)
	if !ok || named.Obj().Pkg() == nil {
		return false
	}
	switch named.Obj().Pkg().Path() {
	case "sync":
		switch named.Obj().Name() {
		case "Mutex", "RWMutex", "Map":
			return true
		}
	case "sync/atomic":
		return true
	}
	return false
}
