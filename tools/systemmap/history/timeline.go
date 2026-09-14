package history

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Commit is one candidate point, read from git before anything is type-checked.
type Commit struct {
	Rev     string
	Date    string
	Subject string
}

// Options configure a timeline run.
type Options struct {
	// Repo is the real repository: where the commits are read from, and where the
	// one curated overlay lives.
	Repo string
	// Ref is the history to walk, first-parent. A squash-merge repository has one
	// commit per change on its default branch, so first-parent is both the shortest
	// walk and the one whose points are the changes people made.
	Ref string
	// Worktree is a scratch checkout the walk moves through. It must not be the
	// user's working tree: the walk checks out several hundred commits into it.
	Worktree string
	// Every keeps one commit in N (1 keeps all). Sampling is for a quick local look
	// or a pull-request build; a walk worth reading keeps every commit, because the
	// point of it is to see the shape move. No pipeline publishes one yet — the Pages
	// job builds the plain map, since the walk costs one type-check per commit.
	Every int
	// Max caps the number of snapshots taken, most recent kept. Zero means no cap.
	Max int
	// RoutePkg is the overlay's route table package, which supplies the service
	// directory to filter commits by and the prefix to translate away from.
	RoutePkg string
	// Overlay is the current overlay's bytes.
	Overlay []byte
	// Progress, when set, is called after each snapshot — including failures, whose
	// error is passed through. A run of several hundred type-checks is long enough
	// that silence would be indistinguishable from a hang.
	Progress func(done, total int, sh *Shape, err error)
}

// Timeline is the artifact: union tables for everything any snapshot contained,
// and one delta-encoded point per commit.
//
// Delta-encoded because the whole point is that consecutive commits are nearly
// identical. Storing each point's full sets would repeat ~1,000 identifiers per
// commit for several hundred commits; storing what changed makes the file roughly
// the size of the changes themselves, which is also the honest shape of the data.
type Timeline struct {
	Ref string `json:"ref"`
	// Head is the revision Ref resolved to, which is not in general the last point:
	// the walk only keeps commits that touched the service, so a documentation commit
	// on top of it leaves the newest point one or more commits behind. The page
	// compares this against the map's own revision, and says so only when the two
	// timelines really were built from different trees.
	Head      string      `json:"head"`
	Routes    []RouteMeta `json:"routes"`
	Nodes     []NodeMeta  `json:"nodes"`
	Links     []LinkRef   `json:"links"`
	Snapshots []Point     `json:"snapshots"`
	// Failed records commits that could not be type-checked at all, so a gap in the
	// timeline is a stated gap rather than a missing point nobody mentions.
	Failed []Failure `json:"failed"`
}

// LinkRef is a wire in the union table: indices into Routes and Nodes, plus the
// access mode. A mode change is a different wire, which is what makes "this
// endpoint started writing what it used to only read" visible as a change.
type LinkRef struct {
	R    int    `json:"r"`
	N    int    `json:"n"`
	Mode string `json:"m"`
}

// Point is one snapshot, as the difference from the one before it.
type Point struct {
	Rev      string   `json:"rev"`
	Date     string   `json:"date"`
	Subject  string   `json:"subject"`
	Module   string   `json:"module"`
	Prefix   string   `json:"prefix"`
	Tables   int      `json:"tables"`
	Fidelity Fidelity `json:"fidelity"`
	// Counts are carried rather than recomputed so the sparkline and the readout
	// need no replay, and so a reader diffing the file can see the shape without
	// running the page.
	Counts Counts `json:"counts"`

	RoutesAdd []int `json:"ra,omitempty"`
	RoutesDel []int `json:"rd,omitempty"`
	NodesAdd  []int `json:"na,omitempty"`
	NodesDel  []int `json:"nd,omitempty"`
	LinksAdd  []int `json:"la,omitempty"`
	LinksDel  []int `json:"ld,omitempty"`
}

// Counts is what the point had, after its deltas are applied.
type Counts struct {
	Routes int `json:"routes"`
	Nodes  int `json:"nodes"`
	Links  int `json:"links"`
}

// Failure is a commit whose extraction did not produce a shape.
type Failure struct {
	Rev    string `json:"rev"`
	Date   string `json:"date"`
	Reason string `json:"reason"`
}

// Commits lists the points to sample: commits on Ref that touched the service,
// oldest first. The path filter is the service directory and the one it used to
// live in — the same candidates Detect tries — because a commit that changed only
// the Swift provider or the console cannot change this map, and type-checking it
// again would add a point identical to its neighbour.
func Commits(opt Options) ([]Commit, error) {
	service := strings.SplitN(opt.RoutePkg, "/", 2)[0]
	args := []string{"log", "--reverse", "--first-parent", "--format=%H%x00%ad%x00%s",
		"--date=short", opt.Ref, "--", service, "internal", "go.mod"}
	cmd := exec.Command("git", args...)
	cmd.Dir = opt.Repo
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("git log %s: %w", opt.Ref, err)
	}
	var all []Commit
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		parts := strings.SplitN(line, "\x00", 3)
		if len(parts) != 3 {
			continue
		}
		all = append(all, Commit{Rev: parts[0], Date: parts[1], Subject: parts[2]})
	}
	// Sampling keeps the newest commit whatever the stride, because a timeline whose
	// last point is not the head is a timeline that disagrees with the map beside it.
	if opt.Every > 1 && len(all) > 0 {
		var kept []Commit
		for i, c := range all {
			if i%opt.Every == 0 || i == len(all)-1 {
				kept = append(kept, c)
			}
		}
		all = kept
	}
	if opt.Max > 0 && len(all) > opt.Max {
		all = all[len(all)-opt.Max:]
	}
	return all, nil
}

// Build walks the commits, snapshots each one, and delta-encodes the result.
func Build(opt Options) (*Timeline, error) {
	if opt.Every <= 0 {
		opt.Every = 1
	}
	commits, err := Commits(opt)
	if err != nil {
		return nil, err
	}
	if len(commits) == 0 {
		return nil, fmt.Errorf("no commits touching the service on %s", opt.Ref)
	}
	if err := prepareWorktree(opt.Repo, opt.Worktree, commits[0].Rev); err != nil {
		return nil, err
	}

	tl := &Timeline{Ref: opt.Ref, Head: resolve(opt.Repo, opt.Ref)}
	routeIdx, nodeIdx, linkIdx := map[string]int{}, map[string]int{}, map[string]int{}
	var prev *Shape
	for i, c := range commits {
		sh, err := snapshotAt(opt, c)
		if opt.Progress != nil {
			opt.Progress(i+1, len(commits), sh, err)
		}
		if err != nil {
			tl.Failed = append(tl.Failed, Failure{Rev: c.Rev, Date: c.Date, Reason: trim(err.Error())})
			continue
		}
		tl.Snapshots = append(tl.Snapshots, encode(tl, sh, prev, routeIdx, nodeIdx, linkIdx))
		prev = sh
	}
	if len(tl.Snapshots) == 0 {
		return nil, fmt.Errorf("every one of %d commits failed to extract; first: %s",
			len(commits), tl.Failed[0].Reason)
	}
	return tl, nil
}

func snapshotAt(opt Options, c Commit) (*Shape, error) {
	cmd := exec.Command("git", "checkout", "--quiet", "--detach", c.Rev)
	cmd.Dir = opt.Worktree
	if out, err := cmd.CombinedOutput(); err != nil {
		return nil, fmt.Errorf("checkout %s: %w: %s", short(c.Rev), err, trim(string(out)))
	}
	return Snapshot(opt.Worktree, opt.Overlay, opt.RoutePkg, c.Rev, c.Date, c.Subject)
}

// encode turns one shape into its difference from the previous one, interning
// every identifier it has not seen before.
//
// Links are encoded last because a wire's entry stores the indices of its two
// endpoints: interning them first is what makes those indices resolvable.
func encode(tl *Timeline, sh, prev *Shape, routeIdx, nodeIdx, linkIdx map[string]int) Point {
	p := Point{
		Rev: sh.Rev, Date: sh.Date, Subject: sh.Subject,
		Module: sh.Module, Prefix: sh.Prefix, Tables: sh.Tables, Fidelity: sh.Fidelity,
		Counts: Counts{Routes: len(sh.Routes), Nodes: len(sh.Nodes), Links: len(sh.Links)},
	}
	p.RoutesAdd, p.RoutesDel = delta(sh.Routes, routesOf(prev), routeIdx,
		func(r RouteMeta) string { return r.Key },
		func(r RouteMeta) { tl.Routes = append(tl.Routes, r) })
	p.NodesAdd, p.NodesDel = delta(sh.Nodes, nodesOf(prev), nodeIdx,
		func(n NodeMeta) string { return n.ID },
		func(n NodeMeta) { tl.Nodes = append(tl.Nodes, n) })
	p.LinksAdd, p.LinksDel = delta(sh.Links, linksOf(prev), linkIdx, linkKey,
		func(l Link) {
			tl.Links = append(tl.Links, LinkRef{R: routeIdx[l.Route], N: nodeIdx[l.Node], Mode: l.Mode})
		})
	return p
}

// delta is the whole encoding: what this point has that the last one did not, and
// what it has lost, as indices into a union table `add` appends to the first time
// each thing is seen.
//
// Deletions carry an index rather than a name because the page replays the
// timeline in both directions — a slider is dragged backwards as often as
// forwards — and undoing a point means re-adding exactly what it removed.
//
// The key is the identity and the metadata beside it is whatever the *first* point
// that carried the key had: `add` runs once per key, so a route that later changed
// namespace or auth class, or a node that moved category, produces no point of its
// own and keeps its oldest description forever. That is a real limit rather than a
// subtlety, and it is bounded: the page reads this table only for what the head
// revision does not have (`page.js` draws everything else from the map itself), so
// what it can get wrong is the namespace a since-deleted route is drawn inside —
// the one it started in rather than the one it was deleted from. Widening the key
// to include the metadata would turn every reclassification into an add plus a
// delete of the same thing, which is a worse lie.
func delta[T any](now, prev []T, idx map[string]int, key func(T) string, add func(T)) (adds, dels []int) {
	before := make(map[string]bool, len(prev))
	for _, v := range prev {
		before[key(v)] = true
	}
	after := make(map[string]bool, len(now))
	for _, v := range now {
		k := key(v)
		after[k] = true
		if before[k] {
			continue
		}
		i, ok := idx[k]
		if !ok {
			i = len(idx)
			idx[k] = i
			add(v)
		}
		adds = append(adds, i)
	}
	for _, v := range prev {
		if k := key(v); !after[k] {
			dels = append(dels, idx[k])
		}
	}
	return adds, dels
}

func prepareWorktree(repo, dir, rev string) error {
	if dir == "" {
		return fmt.Errorf("no scratch worktree given; refusing to check out history into the working tree")
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		return err
	}
	repoAbs, err := filepath.Abs(repo)
	if err != nil {
		return err
	}
	if abs == repoAbs {
		return fmt.Errorf("scratch worktree %s is the repository itself; the walk would check out history over the working tree", abs)
	}
	if _, err := os.Stat(filepath.Join(abs, ".git")); err == nil {
		return nil // an earlier run left it; the walk checks out into it anyway
	}
	cmd := exec.Command("git", "worktree", "add", "--quiet", "--detach", abs, rev)
	cmd.Dir = repoAbs
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("git worktree add %s: %w: %s", abs, err, trim(string(out)))
	}
	return nil
}

// RemoveWorktree cleans up the scratch checkout. Failure is not fatal to a run
// that already produced its artifact, so the caller decides how loudly to say so.
//
// The path is resolved the way `prepareWorktree` resolves it — against the working
// directory rather than against the repository — because the two have to name the
// same directory. Running `git worktree remove` from inside the repository would
// otherwise read a relative `-worktree` as relative to *that*, and refuse to remove
// the checkout the walk had just created somewhere else.
func RemoveWorktree(repo, dir string) error {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return err
	}
	cmd := exec.Command("git", "worktree", "remove", "--force", abs)
	cmd.Dir = repo
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("git worktree remove %s: %w: %s", abs, err, trim(string(out)))
	}
	return nil
}

// Marshal writes the timeline as the page reads it.
func (t *Timeline) Marshal() ([]byte, error) {
	raw, err := json.Marshal(t)
	if err != nil {
		return nil, err
	}
	return append(raw, '\n'), nil
}

func routesOf(s *Shape) []RouteMeta {
	if s == nil {
		return nil
	}
	return s.Routes
}

func nodesOf(s *Shape) []NodeMeta {
	if s == nil {
		return nil
	}
	return s.Nodes
}

func linksOf(s *Shape) []Link {
	if s == nil {
		return nil
	}
	return s.Links
}

// linkKey identifies a wire by both endpoints *and* its access mode, so an
// endpoint that starts writing state it used to only read is encoded as a wire
// removed and a wire added — a change in the picture rather than a silent
// recolouring.
func linkKey(l Link) string { return l.Route + "\x00" + l.Node + "\x00" + l.Mode }

// resolve turns the ref into the commit it names. A failure is not fatal: the head is
// only used to tell a reader that the timeline and the map came from different trees,
// and an empty one means the page does not make that claim either way.
func resolve(repo, ref string) string {
	cmd := exec.Command("git", "rev-parse", ref)
	cmd.Dir = repo
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func short(rev string) string {
	if len(rev) > 9 {
		return rev[:9]
	}
	return rev
}

func trim(s string) string {
	s = strings.TrimSpace(s)
	if len(s) > 300 {
		return s[:300] + "…"
	}
	return s
}
