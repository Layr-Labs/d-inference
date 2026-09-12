# Executing the generated explorer

`render/page.js` is the user-facing half of the system map: ~1.6k lines of filters,
layout, label placement and provenance views, all shipped inside one generated
`system-map.html`. The Go tests in `../..` assert about the *text* of that artifact —
that the control is in the markup, that the function the explorer needs was emitted.
Those checks catch a template that stopped injecting the script. They cannot catch a
script that throws on line one.

This suite loads the generated page into a DOM, runs it, and drives it.

```
make -C tools/systemmap webdeps    # npm ci (jsdom)
make -C tools/systemmap webtest    # build the real map, then drive it
make -C tools/systemmap test       # go test, which runs this over the fixture page
```

`go test` reaches it through `TestPageExecutes` (`../../webtest_test.go`): that test
renders the five-route fixture, writes it to a temp dir, and shells to
`node --test`. It **skips** when node or `node_modules` is missing, so a Go-only
checkout still passes `go test ./...`; CI sets `SYSTEMMAP_WEBTEST=1`, which turns
every such skip into a failure, and separately runs every `*.test.mjs` against the
real coordinator map — 101 routes, 6 clusters, 20 groups, 840 associations.

The two gates — the Go driver and the CI step — check the tally *and* the exit code,
and both discover the suite by glob rather than by list, so a new `*.test.mjs` raises
the floor it is measured against instead of running unrequired. The Go driver also
reads the `.mjs` files itself, so that editing one invalidates its test-cache entry.
All of that is aimed at one failure mode: a suite whose tests stopped being collected
exits zero, and a green run that executed nothing is worse than a red one.
`make webtest` and `npm test` are the local loop and check neither — they propagate
node's exit status, which is enough to see a failure you are looking at and not
enough to be a gate.

The real map is what genuinely crowds the label pass, and two claims rest on it
alone: that the label budget is ever the binding constraint (the fixture has too few
nodes to reach it, and the test says so out loud rather than passing vacuously), and
that a cluster name ever has to climb its rung ladder to get clear. Locally the
nearest thing is the test that lays the same map out in a 420×320 frame — enough to
make the collision pass do real work, not a substitute for the real artifact, which
is why CI drives both.

Both entry points point the suite at a page through one variable, `SYSTEMMAP_PAGE`.
Every assertion is derived from the inventory embedded in that page rather than
hard-coded, which is why the same files run over either artifact.

## What the two files cover

`explorer.test.mjs` — the reading surface. The page executes with no errors and
draws the whole inventory; search, namespace, auth class, access mode and identity
filters each agree with the inventory and compose; the Postgres table drawer shows
every derived column with its declaration site; a node click focuses its own edges
and Escape clears it; full screen toggles, relabels its control and refits; the code
view withholds every string no compiler stands behind and keeps the drawn topology;
the overlay view marks all three curated layers in place; every drawn association and
every line of the pinned panel carries its own endpoint's access mode rather than its
namespace's aggregate; deep links, boundary chips, cluster keys, endpoint rows and
hovers do what they say.

`graph.test.mjs` — the picture. Every node is drawn inside its group disc and every
group inside its cluster's; two group discs never overlap; **every label is on the
thing it names, no two of them overlap, and none is off screen** — at every zoom the
reader can reach, in a full frame and in a deliberately cramped one, after a pan,
after a wheel zoom, after a drag, under a filter, a focus and a hover, and in full
screen — while every boundary keeps its name; the label budget is never exceeded and
endpoint names are earned by zooming in; the topology fingerprint notices a node or an
association leaving the picture and is unchanged by every zoom, pan, filter, view,
focus, drag and full-screen round trip; a node drag stays inside its own boundary,
re-paths its edges and carries its own name with it; the canvas pans by exactly the
gesture; the wheel zooms about the pointer; full screen is a larger frame the picture
is refitted into; and two loads of the same page draw the identical layout.

The "on the thing it names" half is load-bearing and was the last thing added. A label
pass that stops running leaves every name exactly where the previous layout put it,
which satisfies no-overlap and on-screen perfectly while every name on screen points
hundreds of pixels away from its own dot — deleting the `placeLabels` call from either
the pan path or the drag path kept the whole suite green until the position of each
label was scored against where the page's own `sx`/`sy` say its subject is.

Those paragraphs are the reason for the harness. The label pass and the topology
fingerprint are the two claims the map makes that no amount of string matching can
reach, and both were already wrong in ways found by running the page: the endpoint
table published its namespace's access mode instead of the endpoint's own (93
divergences in the real map, so "writes only" selected endpoints that only read), and
two cluster names printed on top of each other when zoomed far out.

## What jsdom proves, and what it does not

It proves: the script parses and runs to the end; every handler the toolbar installs
runs; the DOM those handlers build is the one the assertions read; and every
geometric decision the page makes is real, because the layout, the zoom transform,
the collision pass and the fingerprint are all computed in JavaScript from numbers
rather than measured off a rendered glyph. A regression in any of that fails here.

It does not prove painting. jsdom applies no layout, so element sizes come from the
stubbed `getBoundingClientRect` in `harness.mjs` (the viewport the test asked for,
which is what makes label placement reproducible across machines, and 1920×1080 while
the fullscreen flag is set, so that "refits into the new frame" is an observable
claim), `ResizeObserver` never fires, and `requestFullscreen` is a flag rather than
the real API. A CSS regression that hides a working control is out of reach, and is
not claimed. The one assertion that leans on the stylesheet is the code view's
ungated-prose sections, where jsdom does resolve the `display:none` rule; it is
commented as such.

One input is missing rather than stubbed, and it is worth naming: the page never
measures text, it estimates glyph width arithmetically, and `labels.mjs` scores
collisions with that same estimate. So the suite proves the collision pass is
consistent with the page's own estimator, not that the estimator matches a real font.
Text width is the only geometric input jsdom cannot supply, so that is the whole of
the gap.

`harness.mjs` holds the loader, the polyfills and the gestures; `labels.mjs`
reconstructs the boxes `placeLabels` reserved, from the coordinates it wrote. It does
not copy the arithmetic: `textW`, `labelBox`, `clusterBox`, `sx`, `sy` and every label
constant are top-level declarations in `page.js` and are read back out of the running
page, because a copy here would keep passing while the page and the copy drifted apart
— and a copy that under-reserved a box by a pixel would report overlaps the page does
not have. Each test loads its own page: the explorer is one long-lived object graph
with a `state` the reader mutates, and a shared page would assert about whatever the
previous test left selected.
