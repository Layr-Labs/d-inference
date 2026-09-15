// Command history derives the system map at every commit that touched the
// analyzed service, and writes the result as one delta-encoded timeline.
//
// The map answers "what is this service"; the timeline answers "what did it
// become". Both are derived by the same extractor, because the repository never
// generated a map before this tool existed — there is no historical artifact to
// recover, only history to re-read. Re-reading it with one program is also the
// only way two points can be compared: a difference between snapshots is a
// difference in the service, never a difference in how it was measured.
//
// The output is not committed, like the map it accompanies. It is generated:
//
//	make -C tools/systemmap history                          # every commit, from genesis
//	make -C tools/systemmap history HISTORY_ARGS="-every 10" # a tenth, for a quick look
//	make -C tools/systemmap timeline                         # this artifact alone
//
// and then embedded into the page by the generator under its -history flag, which
// the `history` target passes for you. Embedding is opt-in rather than "read the
// file if it is lying there": a map of one commit and a map you can walk are two
// different artifacts, and which one got built should be something the command
// line said. So this command failing means no slider, loudly, rather than a page
// that quietly carries last week's walk.
package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/tools/systemmap/history"
)

const (
	defaultOverlay  = "docs/reference/api-map/overlay.json"
	defaultOut      = "docs/reference/api-map/history.json"
	defaultRoutePkg = "coordinator/api"
)

func main() {
	var (
		repo     = flag.String("repo", "", "repository to read history from (default: the git root of the working directory)")
		ref      = flag.String("ref", "HEAD", "ref whose first-parent history to walk")
		overlay  = flag.String("overlay", defaultOverlay, "curated overlay, relative to repo")
		out      = flag.String("out", defaultOut, "timeline output path, relative to repo")
		routePkg = flag.String("route-package", defaultRoutePkg, "the overlay's route table package, whose prefix each snapshot is translated to")
		worktree = flag.String("worktree", "", "scratch worktree the walk checks commits out into (default: a temporary directory)")
		every    = flag.Int("every", 1, "keep one commit in N")
		max      = flag.Int("max", 0, "cap the number of snapshots, keeping the most recent (0: no cap)")
		keep     = flag.Bool("keep-worktree", false, "leave the scratch worktree behind, so a repeated run re-checks-out instead of re-cloning")
		quiet    = flag.Bool("quiet", false, "only print the summary")
	)
	flag.Parse()

	if err := run(*repo, *ref, *overlay, *out, *routePkg, *worktree, *every, *max, *keep, *quiet); err != nil {
		fmt.Fprintln(os.Stderr, "systemmap-history:", err)
		os.Exit(1)
	}
}

func run(repo, ref, overlayPath, outPath, routePkg, worktree string, every, max int, keep, quiet bool) error {
	if repo == "" {
		found, err := gitRoot()
		if err != nil {
			return err
		}
		repo = found
	}
	repo, err := filepath.Abs(repo)
	if err != nil {
		return err
	}
	overlay, err := os.ReadFile(filepath.Join(repo, overlayPath))
	if err != nil {
		return err
	}
	if worktree == "" {
		// Outside the repository on purpose. A nested worktree would show up in the
		// working tree the map is generated from, and the walk checks out several
		// hundred commits into it.
		worktree = filepath.Join(os.TempDir(), "systemmap-history-"+filepath.Base(repo))
	}

	started := time.Now()
	opt := history.Options{
		Repo: repo, Ref: ref, Worktree: worktree,
		Every: every, Max: max, RoutePkg: routePkg, Overlay: overlay,
	}
	if !quiet {
		opt.Progress = func(done, total int, sh *history.Shape, err error) {
			if err != nil {
				fmt.Printf("[%4d/%d] failed: %s\n", done, total, oneLine(err.Error()))
				return
			}
			fmt.Printf("[%4d/%d] %s %s  routes=%-4d nodes=%-4d links=%-5d %s  %s\n",
				done, total, sh.Date, short(sh.Rev), len(sh.Routes), len(sh.Nodes), len(sh.Links),
				coverage(sh.Fidelity), truncate(sh.Subject, 56))
		}
	}
	tl, err := history.Build(opt)
	if err != nil {
		return err
	}

	raw, err := tl.Marshal()
	if err != nil {
		return err
	}
	dest := filepath.Join(repo, outPath)
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(dest, raw, 0o644); err != nil {
		return err
	}

	if !keep {
		// Reported, not fatal: the artifact is already on disk, and a worktree that
		// would not go away is a thing to tell someone about rather than a reason to
		// throw away twenty minutes of work.
		if err := history.RemoveWorktree(repo, worktree); err != nil {
			fmt.Fprintln(os.Stderr, "systemmap-history: leaving scratch worktree behind:", err)
		}
	}

	first, last := tl.Snapshots[0], tl.Snapshots[len(tl.Snapshots)-1]
	fmt.Printf("systemmap-history: %d snapshots %s → %s, %d routes / %d nodes / %d wires ever, %s in %s → %s\n",
		len(tl.Snapshots), first.Date, last.Date,
		len(tl.Routes), len(tl.Nodes), len(tl.Links),
		size(len(raw)), time.Since(started).Round(time.Second), outPath)
	if len(tl.Failed) > 0 {
		fmt.Printf("systemmap-history: %d commits could not be extracted, first %s: %s\n",
			len(tl.Failed), short(tl.Failed[0].Rev), oneLine(tl.Failed[0].Reason))
	}
	return nil
}

// coverage renders a snapshot's fidelity the short way, and says nothing when
// there is nothing to say — several hundred progress lines are easier to read
// when the ones worth looking at are the ones with text on them.
func coverage(f history.Fidelity) string {
	var parts []string
	if f.Unmapped > 0 {
		parts = append(parts, fmt.Sprintf("unmapped=%d", f.Unmapped))
	}
	if f.Unlabeled > 0 {
		parts = append(parts, fmt.Sprintf("unlabeled=%d", f.Unlabeled))
	}
	// Every field of Fidelity is printed. A counter recorded per snapshot that no
	// reader can reach is worse than no counter: it looks like coverage the walk is
	// watching, and nothing would notice it climbing.
	if f.Unclassified > 0 {
		parts = append(parts, fmt.Sprintf("unclassified=%d", f.Unclassified))
	}
	return strings.Join(parts, " ")
}

func gitRoot() (string, error) {
	out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return "", fmt.Errorf("not in a git repository; pass -repo")
	}
	return strings.TrimSpace(string(out)), nil
}

func short(rev string) string {
	if len(rev) > 9 {
		return rev[:9]
	}
	return rev
}

func oneLine(s string) string {
	return truncate(strings.Join(strings.Fields(s), " "), 160)
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}

func size(bytes int) string {
	switch {
	case bytes >= 1<<20:
		return fmt.Sprintf("%.1f MiB", float64(bytes)/(1<<20))
	case bytes >= 1<<10:
		return fmt.Sprintf("%d KiB", bytes/(1<<10))
	}
	return fmt.Sprintf("%d B", bytes)
}
