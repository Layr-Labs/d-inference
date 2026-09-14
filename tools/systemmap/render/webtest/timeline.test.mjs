// The history slider, driven in a DOM.
//
// The claims here are about a page whose graph can be moved backwards through the
// service's own commits while everything below it — the tables, the panels, the counts —
// keeps describing the head revision. Three of them matter more than the rest:
//
//   1. A timeline embedded changes nothing until a reader touches it. The page someone
//      lands on is the map of its own commit, byte-identical in what it draws to the
//      same page with no history beside it.
//   2. The newest point reproduces that map exactly. If it does not, the slider's
//      right-hand end is a lie about the present, and every position left of it is a
//      lie about the past by the same amount.
//   3. Reset puts it back, because the position is one of the things a reader chose to
//      look at, like a filter.
//
// All three are asserted as the drawn topology's fingerprint, which the page computes
// from what it actually put in the DOM — every node's id, boundary and cluster, and
// every wire's endpoints and access mode — so they are claims about the picture rather
// than about the bookkeeping behind it.
//
// The fixture is synthetic and its newest point is derived from the map's own inventory
// (timeline.mjs). A real timeline means one full type-check per commit and a checkout
// with the right history in it, neither of which belongs in a DOM test — and a fixture
// can state a wire whose access mode changed, which no particular repository can be
// relied on to contain.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { load, inventory, visible, frame } from './harness.mjs';
import { encode, fixture, headShape, GONE_ROUTE, GONE_NODE } from './timeline.mjs';

const D = inventory();
// One fixture for the whole file: building it walks the inventory's routes and edges,
// and every test loads its own page from the same JSON.
const F = fixture(D, { head: D.revision });
const TL = F.timeline;
const LAST = TL.snapshots.length - 1;

const open = (t, opts = {}) => load({ t, timeline: TL, ...opts });
const topo = p => p.text('#topo');
const engaged = p => p.peek('TL.engaged');
const at = p => p.peek('TL.i');
// Moving the slider the way a reader does: `input`, because that is the event the page
// listens for, and the value has to be set on the element rather than passed to a
// function or nothing about the wiring is under test.
const slide = (p, n) => p.type('#gtrange', String(n));
const cls = (p, sel) => p.$$(sel).map(e => e.getAttribute('class') || '');
// An array read out of the page belongs to the page's realm, and `assert.deepEqual` in
// strict mode compares prototypes — so a list that came back through `peek` has to be
// copied into this realm before it can be compared to a literal.
const list = (p, expr) => [...p.peek(expr)];

// Waiting on something the page does on its own clock. A fixed sleep would be a guess
// about how long a full redraw takes in a DOM with no compositor, which is both slower
// than the interval it is scheduled at and different on every machine.
async function until(done, why, ms = 15000) {
  const stop = Date.now() + ms;
  while (!done()) {
    if (Date.now() > stop) assert.fail(why);
    await new Promise(resolve => setTimeout(resolve, 20));
  }
}

test('a page with no history has no slider, and says nothing about one', t => {
  const p = load({ t });
  assert.equal(p.peek('TL'), null, 'TL exists without a timeline embedded');
  assert.equal(p.$('#gtime').hidden, true, 'the bar is showing with no history to show');
  assert.equal(p.text('#gtnote'), '');
});

// The load-time picture is the whole of claim 1: the fingerprint is computed from the
// DOM, so equality here means the two pages drew the same nodes in the same boundaries
// with the same wires in the same colours.
test('a timeline embedded changes nothing about the map until it is touched', t => {
  const bare = load({ t });
  const p = open(t);
  assert.equal(topo(p), topo(bare), 'embedding a history changed what the page draws');
  assert.equal(engaged(p), false);
  assert.equal(p.$('#gtime').hidden, false, 'the bar is hidden with a history to show');
  assert.equal(at(p), LAST, 'the page did not land on the head revision');
  assert.match(p.text('#gtnote'), /Drag the slider/,
    'an untouched timeline does not tell the reader what it is');
  assert.equal(p.doc.body.classList.contains('travelling'), false);
});

// Claim 2. The last point is the head shape by construction (headShape reads it out of
// the inventory), so this is the assertion that the encoding, the replay, and every
// class the page sets from them agree with the map the page already drew — including the
// wire modes, which is where getting it wrong repainted a tenth of the picture.
test('the newest point reproduces the map exactly', t => {
  const p = open(t);
  const before = topo(p);
  slide(p, 0);
  slide(p, LAST);
  assert.equal(engaged(p), true, 'dragging the slider did not engage the timeline');
  assert.equal(at(p), LAST);
  // Said precisely first, so a mismatch names the endpoint or the wire rather than
  // printing two hashes.
  const live = list(p, 'GNODES.filter(n => tlLive(n)).map(n => n.id).sort()');
  const want = list(p, 'GNODES.filter(n => !n.hist).map(n => n.id).sort()');
  assert.deepEqual(live, want, 'the last point holds a different set of things than the head revision');
  const modes = list(p, 'GLINKS.filter(l => tlWire(l)).map(l => l.key + "=" + l.mode).sort()');
  const heads = list(p, 'GLINKS.filter(l => !l.hist).map(l => l.key + "=" + l.mode0).sort()');
  assert.deepEqual(modes, heads, 'the last point draws different wires, or draws them in different colours');
  assert.equal(topo(p), before, 'returning the slider to the newest commit did not reproduce the map');
});

test('Now returns to the head revision from anywhere', t => {
  const p = open(t);
  const before = topo(p);
  slide(p, 1);
  assert.notEqual(topo(p), before, 'an earlier commit draws the same picture as the head revision');
  p.press('#gtnow');
  assert.equal(at(p), LAST);
  assert.equal(topo(p), before);
});

// Claim 3. Reset is the page's one control that undoes everything a reader chose, and
// the position on the timeline is such a choice — so it also stops travelling, rather
// than leaving the picture at some commit with every filter cleared around it.
test('Reset puts the page back to being a map of one revision', t => {
  const p = open(t);
  const before = topo(p);
  slide(p, 0);
  p.press('#reset');
  assert.equal(engaged(p), false, 'Reset left the timeline engaged');
  assert.equal(at(p), LAST);
  assert.equal(topo(p), before);
  assert.equal(p.doc.body.classList.contains('travelling'), false);
  assert.match(p.text('#gtnote'), /Drag the slider/);
});

test('an earlier commit draws what it had and hides what it did not', t => {
  const p = open(t);
  slide(p, 0);
  const p0 = F.shapes[0];
  // What the point held, as the page's own live sets — endpoints keyed the way the
  // timeline keys them, which is how a route survives having no inventory id.
  const routes = new Set(p0.routes.map(r => r.key));
  const nodes = new Set(p0.nodes.map(n => n.id));
  for (const n of p.peek('GNODES')) {
    const held = n.kind === 'ep' ? routes.has(n.name) : nodes.has(n.dep);
    assert.equal(p.peek(`tlLive(gById[${JSON.stringify(n.id)}])`), held,
      `${n.id} is ${held ? 'missing from' : 'drawn at'} a commit that ${held ? 'had' : 'did not have'} it`);
  }
  // And the picture is smaller for it: what the page decided to show shrank.
  const shown = p.peek('L.shown.size');
  p.press('#gtnow');
  assert.ok(shown < p.peek('L.shown.size'),
    'the first commit draws as many things as the head revision');
});

test('what a revision never had is absent, and out of the fingerprint', t => {
  const p = open(t);
  slide(p, 0);
  // The endpoints the head has and this commit did not: drawn as nothing at all, not as
  // something greyed out. A reader looking at April must not be shown September.
  const absent = cls(p, '#gnodes > g.absent').length;
  assert.ok(absent > 0, 'no node is absent at the first commit, which had a fraction of the routes');
  const inFingerprint = p.$$('#gnodes > g[data-topo]:not(.absent):not(.went)').length;
  const drawn = p.$$('#gnodes > g[data-topo]').length;
  assert.equal(inFingerprint + absent + cls(p, '#gnodes > g.went').length, drawn,
    'a node is neither absent, gone, nor part of the topology');
});

// The difference between "this is not here" and "this commit removed this". A ghost is
// still drawn — that is the point of it — and is still out of the fingerprint, because
// what a commit deleted is not part of what it contained.
test('what a commit removed is ghosted rather than hidden', t => {
  const p = open(t);
  slide(p, 1); // the commit the deleted subsystem goes away in
  const route = p.peek(`gByEp[${JSON.stringify(GONE_ROUTE)}]`);
  assert.ok(route, 'the fixture\'s deleted endpoint did not become a node in the graph');
  const g = p.peek(`gByEp[${JSON.stringify(GONE_ROUTE)}].g`);
  assert.ok(g.classList.contains('went'), 'the endpoint this commit removed is not ghosted');
  assert.equal(g.classList.contains('absent'), false, 'a ghost is not drawn at all');
  const node = p.peek(`gById[${JSON.stringify('dep:' + GONE_NODE)}].g`);
  assert.ok(node.classList.contains('went'), 'the table this commit removed is not ghosted');
  // One commit earlier it was simply there, and one commit later it is simply gone.
  slide(p, 0);
  const before = p.peek(`gByEp[${JSON.stringify(GONE_ROUTE)}].g`);
  assert.deepEqual([before.classList.contains('went'), before.classList.contains('absent')], [false, false],
    'the commit that had the endpoint draws it as removed or as missing');
  slide(p, 2);
  const after = p.peek(`gByEp[${JSON.stringify(GONE_ROUTE)}].g`);
  assert.ok(after.classList.contains('absent'),
    'an endpoint removed two commits ago is still ghosted, so every later commit accuses itself of deleting it');
});

test('a since-deleted endpoint is drawn in the namespace it belonged to', t => {
  const p = open(t);
  slide(p, 0);
  const n = p.peek(`gByEp[${JSON.stringify(GONE_ROUTE)}]`);
  assert.equal(n.hist, true);
  assert.notEqual(n.cluster, '_unplaced',
    'a historical endpoint whose namespace the overlay still knows landed outside every boundary');
  assert.equal(n.group, F.shapes[0].routes.find(r => r.key === GONE_ROUTE).group);
});

// A wire's colour is a fact about the commit, not about the head revision. This is the
// case the union table's identity exists for: the same two endpoints, twice, with
// different modes — and the removal has to be applied before the addition or the
// survivor is deleted instead of recoloured.
test('a wire whose access mode changed is drawn in the new colour', t => {
  const p = open(t);
  const key = JSON.stringify(F.changed.route + '\0' + F.changed.node);
  const link = () => p.peek(`GLINKS.find(l => l.key === ${key})`);
  assert.equal(link().mode, F.changed.head, 'the map does not draw the wire the fixture changed');
  slide(p, 2);
  const then = link();
  assert.equal(then.mode, F.changed.then, 'the wire kept its head-revision access mode at a commit that changed it');
  assert.ok(then.node.getAttribute('data-topo').endsWith(':' + F.changed.then),
    'the recoloured wire is not recoloured in the fingerprint');
  assert.equal(p.peek(`tlWire(GLINKS.find(l => l.key === ${key}))`), true,
    'a wire whose mode merely changed was dropped instead of recoloured');
  p.press('#gtnow');
  assert.equal(link().mode, F.changed.head, 'the wire did not go back to what the head revision does');
});

// The arrowhead is a second element carrying the same colour, and which head a wire
// points with is cached per wire so that hovering does not rewrite eight hundred
// attributes. The cache is keyed on the marker's id rather than on "has a head", because
// the timeline can recolour a wire without changing whether it carries one — and a stale
// key leaves the head at the previous commit's access mode, which no fingerprint sees.
test('a recoloured wire gets a recoloured arrowhead', t => {
  const p = open(t);
  // Every wire pointed, rather than only the ones being read: the budget rule would
  // otherwise decide this test's subject for it.
  while (p.peek('state.arrows') !== 'all') p.press('#garrows');
  const key = JSON.stringify(F.changed.route + '\0' + F.changed.node);
  const head = () => p.peek(`GLINKS.find(l => l.key === ${key})`).node.getAttribute('marker-end');
  const before = head();
  assert.ok(before, 'the wire carries no arrowhead with arrows forced on, so there is none to recolour');
  slide(p, 2);
  assert.notEqual(head(), before, 'the wire changed access mode and its arrowhead did not');
  assert.ok(head().endsWith('-' + F.changed.then + ')'),
    `arrowhead ${head()} does not name the wire's new access mode (${F.changed.then})`);
  p.press('#gtnow');
  assert.equal(head(), before, 'the arrowhead did not go back with the wire');
});

test('an association the head revision does not have is drawn at the commit that had it', t => {
  const p = open(t);
  const key = JSON.stringify(F.head.routes[0].key + '\0' + GONE_NODE);
  const l = p.peek(`GLINKS.find(l => l.key === ${key})`);
  assert.ok(l, 'a wire recorded only in the union table was never drawn');
  assert.equal(l.hist, true);
  assert.equal(p.peek(`tlWire(GLINKS.find(l => l.key === ${key}))`), false,
    'a wire the head revision does not have is live before the timeline is touched');
  slide(p, 0);
  assert.equal(p.peek(`tlWire(GLINKS.find(l => l.key === ${key}))`), true,
    'the commit that had the association does not draw it');
});

test('the readout follows the slider', t => {
  const p = open(t);
  slide(p, 1);
  const pt = TL.snapshots[1];
  assert.equal(p.text('#gtdate'), pt.date);
  assert.equal(p.text('#gtrev'), pt.rev.slice(0, 9));
  assert.equal(p.text('#gtsubject'), pt.subject);
  assert.equal(p.text('#gtpos'), '· commit 2 of ' + TL.snapshots.length);
  assert.match(p.text('#gtcounts'), new RegExp('^' + pt.counts.routes + ' endpoints · ' +
    pt.counts.nodes + ' dependencies · ' + pt.counts.links + ' wires'));
  // The delta is against the commit before, and it is signed.
  const d = pt.counts.routes - TL.snapshots[0].counts.routes;
  assert.match(p.text('#gtdelta'), new RegExp((d > 0 ? '\\+' : '−') + Math.abs(d) + ' endpoints'));
  // And the first commit has nothing to be a delta against.
  slide(p, 0);
  assert.equal(p.text('#gtdelta'), '', 'the first commit reports a delta against nothing');
});

test('the commit link points at the commit', t => {
  const p = open(t);
  slide(p, 1);
  const href = p.$('#gtrev').getAttribute('href');
  if (href) {
    assert.ok(href.endsWith(TL.snapshots[1].rev), `${href} does not name the commit`);
    assert.ok(href.includes('/commit/'), `${href} is not a commit URL`);
  }
});

test('the diff names what the commit changed, and says so when it changed nothing', t => {
  const p = open(t);
  slide(p, 1);
  const chips = p.$$('#gtdiff .chip').map(c => c.textContent);
  assert.ok(chips.some(c => c.includes(GONE_ROUTE)),
    `the removed endpoint is not in the diff: ${JSON.stringify(chips)}`);
  assert.ok(chips.some(c => c.startsWith('−')), 'nothing in the diff is marked as removed');
  assert.ok(chips.some(c => c.startsWith('+')), 'nothing in the diff is marked as added');
  // A chip for something the head revision does not have cannot select it, and says so
  // rather than being a dead click.
  const dead = p.$$('#gtdiff .chip.gtdead').map(c => c.textContent);
  assert.ok(dead.some(c => c.includes(GONE_ROUTE)),
    'the removed endpoint is offered as selectable in an inventory that has never heard of it');
  // The shapeless commit.
  slide(p, 3);
  assert.equal(p.$$('#gtdiff .chip').length, 0);
  assert.match(p.text('#gtdiff'), /without changing its shape/);
});

test('a diff chip selects the thing it names when the head revision still has it', t => {
  const p = open(t);
  slide(p, 1);
  const chip = p.$$('#gtdiff .chip:not(.gtdead)')[0];
  assert.ok(chip, 'no commit in the fixture added anything the head revision still has');
  p.click(chip);
  assert.ok(p.peek('state.open') || p.peek('state.dep'),
    'clicking a diff chip selected nothing');
});

test('the note says the point was derived by today’s extractor, and where that shows', t => {
  const p = open(t);
  slide(p, 0);
  const note = p.text('#gtnote');
  assert.match(note, /today’s extractor/);
  assert.match(note, /4 fields this commit reached have no node/,
    'a point with unmapped fields does not say the picture is missing them');
  assert.match(note, /Dashed amber/, 'the note does not explain the ghosts it is drawing');
  assert.match(note, /tables below still describe the head revision/);
});

// A hole in the axis. The walk type-checks every commit with today's toolchain, so an old
// one can fail to load for reasons that say nothing about whether it worked at the time;
// such a commit is dropped from the walk. That has a consequence a reader would otherwise
// have to guess at — the dropped commit's changes appear on the next point that did
// extract, so one point can carry two unrelated changes — and the artifact records them,
// so there is no excuse for the page not to say how many there were.
test('the note says how many commits are missing from the axis', t => {
  const clean = open(t);
  assert.doesNotMatch(clean.text('#gtnote'), /could not be type-checked/,
    'a walk that dropped nothing warns about commits it did not drop');

  const holes = f => {
    const p = load({ t, timeline: { ...TL, failed: f } });
    slide(p, 0);
    return p.text('#gtnote');
  };
  assert.match(holes([{ rev: 'f00000000', date: '2026-04-02', reason: 'no go.mod' }]),
    /1 commit in this range could not be type-checked/,
    'a walk with a dropped commit says nothing about it');
  // Plural, and the sentence has to agree — a count printed into prose is the easiest
  // place for a page to say something ungrammatical about its own data.
  const many = holes([{ rev: 'f00000000', date: '2026-04-02', reason: 'no go.mod' },
    { rev: 'f00000001', date: '2026-04-03', reason: 'broken import' }]);
  assert.match(many, /2 commits in this range could not be type-checked .* and are not on the axis/);
  assert.doesNotMatch(many, /2 commits .* is not on the axis/);
  // And the consequence, which is the reason the count is worth printing at all.
  assert.match(many, /shows up on the next point/);
});

test('a timeline built at another revision says so, and one built at this one does not', t => {
  const quiet = open(t);
  slide(quiet, 0);
  assert.doesNotMatch(quiet.text('#gtnote'), /may differ/,
    'a timeline built at the map\'s own revision warns about a difference it does not have');
  const other = load({ t, timeline: { ...TL, head: 'deadbeefdeadbeefdeadbeef' } });
  slide(other, 0);
  assert.match(other.text('#gtnote'), /This timeline was built at deadbeefd/);
});

test('one point is a map, not a history', t => {
  const p = load({ t, timeline: encode([F.shapes[LAST]]) });
  assert.equal(p.peek('TL'), null, 'a single-point timeline became a slider with one stop');
  assert.equal(p.$('#gtime').hidden, true);
  assert.equal(topo(p), topo(load({ t })), 'a single-point timeline changed the map');
});

// An artifact that is present and says nothing costs the reader a slider, not the map.
// The page's own error path, rather than a claim about JSON.parse.
test('a timeline with no points is ignored rather than fatal', t => {
  const p = load({ t, timeline: { ref: 'refs/heads/test', head: '', routes: [], nodes: [], links: [], snapshots: [] } });
  assert.equal(p.peek('TL'), null);
  assert.equal(p.$('#gtime').hidden, true);
  assert.equal(topo(p), topo(load({ t })), 'an empty timeline changed the map');
});

test('stepping keys move one commit, and do not fire while the reader is typing', t => {
  const p = open(t);
  p.key('ArrowLeft');
  assert.equal(at(p), LAST - 1, '← did not step back one commit');
  p.key('ArrowRight');
  assert.equal(at(p), LAST, '→ did not step forward one commit');
  // The search box swallows them, or every letter typed would also move the history.
  const q = p.$('#q');
  q.dispatchEvent(new p.win.KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true }));
  assert.equal(at(p), LAST, 'typing in the search box moved the timeline');
  // And so does a button, for Space: that is how a keyboard reader presses the control
  // they have tabbed to, so taking it here would break every button on the page — and
  // break it invisibly, since nothing tells them a slider took the keypress.
  const btn = p.$('#gfull');
  btn.dispatchEvent(new p.win.KeyboardEvent('keydown', { key: ' ', bubbles: true }));
  assert.equal(p.peek('TIME.timer'), null,
    'Space on a focused button started the history playing instead of pressing the button');
  // And the ends hold.
  slide(p, 0);
  p.key('ArrowLeft');
  assert.equal(at(p), 0, 'stepping back off the first commit went somewhere else');
});

test('space plays the history forward and stops at the head revision', async t => {
  const p = open(t);
  p.key(' ');
  assert.ok(p.peek('TIME.timer'), 'Space did not start playing');
  assert.equal(at(p), 0, 'playing from the head revision did not start from the beginning');
  assert.equal(p.text('#gtplay'), '❙❙', 'the play button does not offer to pause');
  // The timer is the page's own, so it is let run rather than reimplemented — and waited
  // on rather than slept past: each tick redraws the whole graph, which in a DOM with no
  // compositor takes longer than the interval it was scheduled at.
  await until(() => p.peek('TIME.timer') === null,
    'playing never stopped; it reached commit ' + at(p) + ' of ' + LAST);
  assert.equal(at(p), LAST, 'playing stopped before the head revision');
  assert.equal(p.text('#gtplay'), '▶', 'the play button still offers to pause');
});

test('touching the slider stops playing', t => {
  const p = open(t);
  p.press('#gtplay');
  assert.ok(p.peek('TIME.timer'));
  slide(p, 2);
  assert.equal(p.peek('TIME.timer'), null, 'dragging the slider left it playing underneath');
  p.press('#gtplay');
  p.press('#gtnow');
  assert.equal(p.peek('TIME.timer'), null, 'Now left it playing');
});

// A focus shadows everything except one node and its wires. Sliding past the commit that
// node was added in would leave the claim pointing at nothing drawn, which reads as a
// page that lost its graph.
test('a focus on something the commit does not have is dropped', t => {
  const p = open(t);
  // An endpoint the head revision has and the first commit does not, so sliding back
  // past it is a real question rather than one the fixture happens not to pose.
  const had = new Set(F.shapes[0].routes.map(r => r.key));
  const late = F.head.routes.map(r => r.key).find(k => !had.has(k));
  assert.ok(late, 'the first commit already has every endpoint the head revision does');
  const node = p.peek(`gByEp[${JSON.stringify(late)}]`);
  p.clickNode(p.peek(`gByEp[${JSON.stringify(late)}].g`));
  assert.equal(p.peek('state.focus'), node.id, 'clicking an endpoint did not focus it');
  slide(p, 0);
  assert.equal(p.peek('state.focus'), null,
    'the focus survived onto a commit that does not contain what it points at');
  assert.equal(p.peek('L.focused'), false, 'the picture is still shadowed for a focus it dropped');
});

// A boundary is drawn from what is inside it. At an early commit most namespaces are
// empty, and an empty ring with a label naming a subsystem that does not exist yet is
// worse than no ring.
test('a boundary with nothing inside it is not drawn and not labelled', t => {
  const p = open(t);
  slide(p, 0);
  const hollow = list(p, '[...L.hollow]');
  assert.ok(hollow.length, 'every boundary still has something in it at the first commit');
  // Its ring is not drawn, and neither is the name that would announce a subsystem the
  // commit does not have yet. Both are read out of the page's own maps of them, because
  // neither element carries its boundary's id as an attribute to select it by.
  const state = 'id => ({ id,' +
    ' ring: !(hullPaths[id] || groupPaths[id]).classList.contains("absent"),' +
    ' label: (hullLabels[id] || groupLabels[id]).style.display !== "none" })';
  const empty = list(p, `[...L.hollow].map(${state})`);
  assert.deepEqual(empty.filter(x => x.ring), [],
    `a boundary with nothing inside it is still drawn: ${JSON.stringify(empty)}`);
  assert.deepEqual(empty.filter(x => x.label), [],
    `a boundary with nothing inside it is still labelled: ${JSON.stringify(empty)}`);
  // And they come back at the head revision, which draws everything.
  const ids = JSON.stringify(hollow);
  p.press('#gtnow');
  const back = list(p, `${ids}.map(${state})`);
  assert.deepEqual(back.filter(x => !x.ring), [],
    `a boundary emptied by an old commit is still undrawn at the head revision: ${JSON.stringify(back)}`);
});

// The graph is exactly what the timeline moves, so a slider left behind on the scrolled
// page underneath full screen is a control for something the reader can no longer see.
test('full screen takes the slider with it, and brings it back', async t => {
  const p = open(t);
  slide(p, 2);
  p.press('#gfull');
  await frame(p);
  const bar = p.$('#gtime');
  assert.ok(bar.classList.contains('gtover'), 'the bar did not dock over the full-screen graph');
  assert.ok(bar.closest('#graph'), 'the bar stayed outside the graph it controls');
  // Same element either way, so the reader's position, the range and the play timer
  // survive the move because nothing is rebuilt.
  assert.equal(at(p), 2, 'going full screen moved the reader');
  assert.equal(p.$('#gtrange').value, '2');
  p.press('#gfull');
  await frame(p);
  assert.equal(bar.classList.contains('gtover'), false);
  assert.ok(bar.closest('.stage'), 'the bar did not come back into the flow');
  assert.ok(!bar.closest('#graph'));
  assert.equal(at(p), 2);
});

// Everything below the graph is the head revision, and stays that way. A reader looking
// at April must not be given an April endpoint table the timeline cannot fill in — it has
// no auth class for it, no citation, no prose.
test('the tables and panels below the graph always describe the head revision', t => {
  const bare = load({ t });
  const p = open(t);
  const rows = () => p.$$('#routes tbody tr').length;
  const before = rows();
  slide(p, 0);
  assert.equal(rows(), before, 'walking back changed the endpoint table');
  assert.deepEqual(p.options('#ns'), bare.options('#ns'),
    'walking back changed what namespaces the reader can filter by');
  assert.deepEqual(p.options('#dep'), bare.options('#dep'),
    'a since-deleted dependency became selectable in the inventory');
  // And no since-deleted endpoint leaked into any of it.
  assert.equal((p.text('#routes') + p.text('#edges')).includes(GONE_ROUTE), false,
    'an endpoint the head revision does not have reached a table that describes it');
  assert.equal(p.peek('DATA.routes.some(r => r.method + " " + r.path === ' +
    JSON.stringify(GONE_ROUTE) + ')'), false, 'a historical endpoint was merged into the inventory');
});

// The panels, which are the half of that claim a table cannot cover. A node's edges are
// the one thing the page keeps in a *shared* structure: every revision's wires are pushed
// into the same `n.links`, because one layout has to serve the whole walk. So a panel that
// reads that list unfiltered describes the union of every commit — and says so in prose,
// with counts and working links, on a page that has not been touched yet.
//
// The fixture's stale wire is the case: an endpoint that survives, reaching a dependency
// that survives, over a wire no commit since has had. Its dependency is normally one that
// nothing reaches today, which makes the wrong answer a categorical one rather than an
// off-by-one — "no endpoint reaches it" versus "one endpoint reaches it, here it is".
test('a panel counts a node’s edges as the head revision has them', t => {
  const bare = load({ t });
  const p = open(t);
  const dep = F.stale.node, ep = F.stale.route;
  // Graph ids, which are not the inventory's keys: an endpoint's dot is keyed by the
  // route's id and only `gByEp` knows the mapping from "METHOD path".
  const epID = p.peek(`gByEp[${JSON.stringify(ep)}].id`);
  const depID = 'dep:' + dep;
  // The wire really is historical, or this test asserts nothing: it must be in the union
  // the page built and absent from the head revision's own wires.
  assert.equal(p.peek(`GLINKS.some(l => l.hist &&
    ((l.s.id === ${JSON.stringify(epID)} && l.t.id === ${JSON.stringify(depID)}) ||
     (l.t.id === ${JSON.stringify(epID)} && l.s.id === ${JSON.stringify(depID)})))`), true,
    `the fixture's stale wire ${ep} → ${dep} is not in the page's union, so nothing here is under test`);

  // Focus each of the two ends and compare the readouts against the same page with no
  // history embedded at all, which is the definition of "describes the head revision".
  const focus = (q, id) => { q.peek(`(focusNode(${JSON.stringify(id)}), draw(), 1)`); return q; };
  for (const id of [epID, depID]) {
    focus(bare, id); focus(p, id);
    assert.equal(p.text('#gfocuscount'), bare.text('#gfocuscount'),
      `with a history embedded, the focus readout for ${id} counts edges the head revision does not have`);
    assert.equal(p.text('#ginfo'), bare.text('#ginfo'),
      `with a history embedded, the panel for ${id} describes a shape no commit had`);
    focus(bare, id); focus(p, id); // focusNode toggles
  }

  // And the loudest form of it, stated on its own so a future change cannot satisfy the
  // comparison above by making both pages wrong together.
  focus(p, depID);
  const info = p.text('#ginfo');
  if (F.stale.headReachers === 0) {
    assert.match(info, /No endpoint reaches it/,
      `${dep} is reached by nothing in the head revision, but its panel names a reacher ` +
      `it only ever had at an earlier commit: ${JSON.stringify(info.slice(0, 300))}`);
    assert.equal(info.includes(ep), false,
      `${dep}'s panel links to ${ep}, which has not reached it since the first commit in the fixture`);
  } else {
    // No \b before the count: the panel's sections are concatenated without separators, so
    // this number is usually preceded by a letter. A digit is what must not precede it.
    assert.match(info, new RegExp('(?<!\\d)' + F.stale.headReachers + ' endpoints? reach it'),
      `${dep} is reached by ${F.stale.headReachers} endpoints at the head revision: ${JSON.stringify(info.slice(0, 300))}`);
  }
});

// The graph is filtered and travelled at the same time, and the two have to compose:
// what a filter picks out of a commit is the intersection, not one overriding the other.
test('filters and the timeline compose', t => {
  const p = open(t);
  slide(p, 0);
  const travelled = p.peek('L.shown.size');
  const ns = F.shapes[0].routes[0].ns;
  p.choose('#ns', ns);
  assert.ok(p.peek('L.shown.size') <= travelled,
    'filtering an earlier commit showed more than the commit had');
  const stray = list(p, '[...L.shown].map(id => gById[id])' +
    `.filter(n => n.kind === "ep" && n.ns !== ${JSON.stringify(ns)}).map(n => n.name)`);
  assert.deepEqual(stray, [], 'an endpoint outside the chosen namespace survived the filter');
  const notThen = list(p, '[...L.shown].filter(id => !tlLive(gById[id]))');
  assert.deepEqual(notThen, [], 'the filter re-showed things the commit does not contain');
});

test('the fixture is a fixture: its newest point is the map’s own shape', () => {
  // Not a claim about the page — a check that the rest of this file is testing what it
  // says it is. A fixture whose last point drifted from the inventory would make every
  // "reproduces the map" assertion above vacuous in the direction that matters.
  const H = headShape(D);
  assert.equal(H.routes.length, D.routes.length);
  assert.equal(H.nodes.length, Object.keys(D.nodes).length);
  assert.ok(H.links.length > 0, 'the head revision has no wires');
  assert.deepEqual(TL.snapshots[LAST].counts,
    { routes: H.routes.length, nodes: H.nodes.length, links: H.links.length });
});
