// Package history derives the system map at many commits, so the shape of a
// service can be read as it changed rather than only as it is.
//
// The extractor is the one today's map uses, pointed at an old checkout: the same
// route table, the same reachability walk, the same access modes. Nothing about a
// snapshot is remembered from when it was current — the repository never generated
// a map before this tool existed, so every point on the timeline is derived now,
// by one program, which is what makes two points comparable.
//
// What that costs is stated rather than hidden. An old commit kept its packages
// somewhere else, and today's overlay is the only thing that can name a node, so a
// snapshot reports how much of its own state the overlay could still account for.
// A point with poor coverage is drawn as a point with poor coverage.
package history

import (
	"fmt"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
)

// Layout is what a snapshot's own tree says about where the analyzed service
// lives. It is detected, not declared: this repository moved its Go module twice
// and renamed its package prefix once, and a curated table of those commits would
// be a second copy of a fact every checkout already states in its go.mod and its
// directory names. Detection also means a snapshot from a branch nobody listed
// still resolves.
type Layout struct {
	// Dir is the directory the type-checker runs in — the one holding go.mod.
	// Today that is the repository root; before the module moved it was
	// `coordinator/`.
	Dir string
	// Module is the module path go.mod declares. It has been three different
	// strings (dginf, eigeninference/coordinator, eigeninference/d-inference) and
	// every import path in the snapshot is relative to whichever one applied.
	Module string
	// Prefix is where the service's packages sit relative to the module root, with
	// a trailing slash: "coordinator/" today, "internal/" while the module lived
	// in coordinator/. Empty means they sit directly at the module root.
	Prefix string
}

var moduleLine = regexp.MustCompile(`(?m)^module\s+(\S+)`)

// Detect reads the layout out of a checkout. routePkg is the overlay's own route
// table package ("coordinator/api"), which supplies both the leaf to look for and
// today's prefix to compare against — so the search is expressed in terms of the
// current map rather than hard-coding this repository's history.
func Detect(root, routePkg string) (Layout, error) {
	// The module root is wherever go.mod is. Only two places are possible: the
	// repository root, or the service directory before the two were unified. The
	// service directory is derived from routePkg's first element for the same
	// reason as above.
	service := strings.SplitN(routePkg, "/", 2)[0]
	var lay Layout
	for _, dir := range []string{root, filepath.Join(root, service)} {
		raw, err := os.ReadFile(filepath.Join(dir, "go.mod"))
		if err != nil {
			continue
		}
		m := moduleLine.FindSubmatch(raw)
		if m == nil {
			return Layout{}, fmt.Errorf("%s/go.mod declares no module path", dir)
		}
		lay = Layout{Dir: dir, Module: string(m[1])}
		break
	}
	if lay.Dir == "" {
		return Layout{}, fmt.Errorf("no go.mod at %s or %s/%s: not a Go checkout of this repository", root, root, service)
	}

	// The package prefix is found by looking for the route table's package. The
	// candidates are the three shapes this map can describe — where it is today,
	// under an `internal/` tree, and directly at the module root — tried
	// outermost-first so the current layout costs one stat.
	leaf := path.Base(routePkg)
	for _, cand := range []string{routePkg, "internal/" + leaf, leaf} {
		if info, err := os.Stat(filepath.Join(lay.Dir, cand)); err == nil && info.IsDir() {
			lay.Prefix = strings.TrimSuffix(cand, leaf)
			return lay, nil
		}
	}
	return Layout{}, fmt.Errorf("no %s package under %s: cannot locate the route table", leaf, lay.Dir)
}
