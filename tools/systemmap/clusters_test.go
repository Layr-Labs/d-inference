package main

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/tools/systemmap/config"
	"github.com/eigeninference/d-inference/tools/systemmap/ir"
	"github.com/eigeninference/d-inference/tools/systemmap/render"
)

// TestFixtureClusters asserts the graph is drawable: every node lands in exactly
// one declared boundary, and the service's own process is one of them. The
// explorer's cluster hulls are only truthful if this holds.
func TestFixtureClusters(t *testing.T) {
	g, _ := buildFixture(t)
	if len(g.Clusters) == 0 {
		t.Fatal("graph carries no clusters, so the explorer cannot draw a boundary")
	}
	for _, svc := range g.Services {
		cluster, ok := g.Clusters[svc.ID]
		if !ok {
			t.Fatalf("service %q has no cluster", svc.ID)
		}
		if cluster.Kind != "service" {
			t.Errorf("cluster %q kind = %q, want \"service\"", svc.ID, cluster.Kind)
		}
	}
	placed := map[string]int{}
	for id, node := range g.Nodes {
		cat, ok := g.Categories[node.Category]
		if !ok {
			t.Errorf("node %q has category %q, which the overlay does not declare", id, node.Category)
			continue
		}
		if _, ok := g.Clusters[cat.Cluster]; !ok {
			t.Errorf("node %q is in category %q whose cluster %q is undeclared", id, node.Category, cat.Cluster)
			continue
		}
		placed[cat.Cluster]++
	}
	// mem.* is coordinator state in the real map and Server state in the fixture:
	// either way it belongs inside the service's own boundary, not beside it.
	if placed["svcfix"] == 0 {
		t.Error("no node landed in the service's own cluster; in-process state must sit inside it")
	}
	for _, want := range []string{"db", "outside"} {
		if placed[want] == 0 {
			t.Errorf("cluster %q holds no nodes", want)
		}
	}
}

// TestClusterDrift proves each way the picture can become undrawable is caught.
// Without these the generator would happily emit nodes with no boundary, or an
// empty boundary with no nodes, and -check would stay green.
func TestClusterDrift(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*config.Config)
		want   string
	}{
		{
			name: "category with no cluster",
			mutate: func(c *config.Config) {
				cat := c.Categories["pg"]
				cat.Cluster = ""
				c.Categories["pg"] = cat
			},
			want: `categories["pg"].cluster`,
		},
		{
			name: "category naming an undeclared cluster",
			mutate: func(c *config.Config) {
				cat := c.Categories["mem"]
				cat.Cluster = "nowhere"
				c.Categories["mem"] = cat
			},
			want: `no such cluster is declared`,
		},
		{
			name: "cluster nothing places nodes in",
			mutate: func(c *config.Config) {
				c.Clusters["ghost"] = ir.Cluster{Title: "Ghost", Kind: "external", Color: "#000"}
			},
			want: `clusters["ghost"]`,
		},
		{
			name:   "service with no cluster",
			mutate: func(c *config.Config) { delete(c.Clusters, "svcfix") },
			want:   `has no cluster to draw its process boundary`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, rep := buildFixture(t, tc.mutate)
			if rep.Clean() {
				t.Fatalf("report is clean; %s should be drift", tc.name)
			}
			found := strings.Join(rep.BadClusters, "\n")
			if !strings.Contains(found, tc.want) {
				t.Errorf("cluster findings do not mention %q:\n%s", tc.want, found)
			}
		})
	}
}

// TestGraphRenders checks the knowledge graph ships in the page: the scaffolding
// the layout attaches to, the cluster titles it draws, and no remote assets (the
// layout and hulls are computed in-page precisely so the artifact stays a single
// file).
func TestGraphRenders(t *testing.T) {
	g, _ := buildFixture(t)
	inventory, err := g.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	page, err := render.HTML(g, inventory)
	if err != nil {
		t.Fatal(err)
	}
	body := string(page)
	for _, want := range []string{
		"Darkbloom system map", // the map is the system's, not one service's
		`id="gsvg"`, `id="hulls"`, `id="glinks"`, `id="gnodes"`,
		"Fixture process", "Third parties", // cluster titles come from the overlay
		`"clusters"`, // the embedded inventory carries the boundaries
	} {
		if !strings.Contains(body, want) {
			t.Errorf("rendered page is missing %q", want)
		}
	}
	if strings.Contains(body, "Coordinator system map") {
		t.Error("page still titles itself after a single service")
	}
}
