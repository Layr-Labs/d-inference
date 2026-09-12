// The label pass, scored from outside.
//
// `placeLabels` in page.js reserves a rectangle per label and refuses one that
// would intersect a rectangle already taken. Nothing about that decision survives
// into the DOM except the coordinates it wrote, so this file reconstructs the boxes
// from those coordinates — using the page's own width estimate and its own box
// geometry, read out of the running page rather than copied here, because the page's
// collision test is what is under test and jsdom measures no text — and hands the
// tests one assertion: nothing the reader can see is drawn on top of anything else.

import assert from 'node:assert/strict';
import { visible } from './harness.mjs';

// Coordinates are written with `toFixed(1)`, so a reconstructed edge can sit up to
// 0.05px from where the page put it, in each axis. The page's own `fits` uses a
// strict `<` — two labels are allowed to touch exactly, and on the real map two of
// them do — so scoring with the same strict test would turn that rounding into a
// phantom overlap. An intersection has to be deeper than the rounding to count.
const EPS = 0.11;

// geom is the page's own label geometry, borrowed. `textW`, `labelBox` and
// `clusterBox` are top-level declarations in page.js precisely so that a test can
// score collisions with the arithmetic the page placed the labels with; a copy here
// would pass while the page and the copy drifted apart.
export const geom = p => ({
  textW: p.peek('textW'),
  labelBox: p.peek('labelBox'),
  clusterBox: p.peek('clusterBox'),
  px: p.peek('LABEL_PX'),
  groupPx: p.peek('GROUP_LABEL_PX'),
  groupH: p.peek('GROUP_LABEL_H'),
  clusterPx: p.peek('CLUSTER_LABEL_PX'),
  clusterSubPx: p.peek('CLUSTER_SUB_PX'),
  groupMin: p.peek('GROUP_LABEL_MIN'),
  epZoom: p.peek('EP_LABEL_ZOOM'),
  seqPx: p.peek('SEQ_PX'),
});

// The wires a focused endpoint is numbering right now, in the order the badges are
// assigned to them: `placeLabels` hands pool slot i to `seqLinks()[i]`, so that
// pairing is what makes a badge scoreable at all — the number in the text says which
// step it is, and this says which wire it was put on.
const seqWires = p => p.peek('seqLinks()');
const seqId = l => l.s.id + '→' + l.t.id;

// The midpoint of a wire as *drawn*, computed here from the path data the page wrote and
// nothing else: `M x y Q cx cy ex ey` at t = 0.5 is (P0 + 2C + P2) / 4, projected with the
// page's screen transform.
//
// This exists because everything else about a badge is scored against `seqSpots`, borrowed
// from the page — which makes the ladder's shape checkable but says nothing about whether
// the ladder is anchored to the right place. A `seqSpots` that read some other wire's
// midpoint, or the untrimmed endpoint instead of the drawn one, would move every badge off
// its line and still satisfy a test that asked the same function where they belong. So the
// base rung is checked against the drawn curve, once per wire, and the borrowed arithmetic
// is trusted only after that.
export function drawnMid(p, l) {
  const sx = p.peek('sx'), sy = p.peek('sy');
  const n = l.node.getAttribute('d').match(/-?[\d.]+/g).map(Number);
  return {
    x: 0.25 * sx(n[0]) + 0.5 * sx(n[2]) + 0.25 * sx(n[4]),
    y: 0.25 * sy(n[1]) + 0.5 * sy(n[3]) + 0.25 * sy(n[5]),
  };
}

// The leader ticks, scored. A badge the ladder had to move is joined back to its wire by a
// dashed tick, and that tick is the only thing in the picture that says which of a fan of
// 57 wires a moved number belongs to — on the widest handler, a badge one rung off its
// midpoint routinely has a *different* wire passing within a pixel of it, so proximity
// cannot carry the pairing and the tick has to. Two claims, per visible badge:
//
//   - a badge further than SEQ_LEAD_MIN from its own drawn midpoint has a tick, and the
//     tick starts on that midpoint (short by the trim, which keeps it off the wire);
//   - a badge nearer than that has none, because the tick would be shorter than the gap.
//
// Ticks are not collision-scored: a tick crosses whatever lies between a number and its
// wire, on purpose, and that is why it is thin and dashed rather than placed.
function assertSeqLeads(p, where) {
  const leads = p.peek('SEQ_LEADS'), pool = p.peek('SEQ_POOL');
  const seqPx = p.peek('SEQ_PX'), min = p.peek('SEQ_LEAD_MIN'), trim = p.peek('SEQ_LEAD_TRIM');
  const wires = seqWires(p);
  for (let i = 0; i < wires.length; i++) {
    const t = pool[i], lead = leads[i];
    if (!t || !visible(t)) continue;
    const mid = drawnMid(p, wires[i]);
    const at = { x: Number(t.getAttribute('x')), y: Number(t.getAttribute('y')) - seqPx / 2 };
    const off = Math.hypot(at.x - mid.x, at.y - mid.y);
    if (off < min) {
      assert.ok(!visible(lead), `badge ${t.textContent} is ${off.toFixed(1)}px from its own ` +
        `wire and still drew a leader ${where}`);
      continue;
    }
    assert.ok(visible(lead), `badge ${t.textContent} sits ${off.toFixed(1)}px off the ` +
      `midpoint of ${seqId(wires[i])} with no leader to say which wire it belongs to ${where}`);
    const x1 = Number(lead.getAttribute('x1')), y1 = Number(lead.getAttribute('y1'));
    const from = Math.hypot(x1 - mid.x, y1 - mid.y);
    assert.ok(Math.abs(from - trim) <= 0.15, `badge ${t.textContent}'s leader starts ` +
      `${from.toFixed(1)}px from the midpoint of ${seqId(wires[i])}, not the ${trim}px trim ` +
      `— it is pointing at the wrong wire ${where}`);
    const x2 = Number(lead.getAttribute('x2')), y2 = Number(lead.getAttribute('y2'));
    const to = Math.hypot(x2 - at.x, y2 - at.y);
    assert.ok(to <= p.peek('SEQ_LEAD_GAP') + 0.15, `badge ${t.textContent}'s leader stops ` +
      `${to.toFixed(1)}px short of the number it belongs to ${where}`);
  }
  // A slot past the current flow keeps no tick, for the same reason it keeps no number.
  for (let i = wires.length; i < leads.length; i++) {
    assert.ok(!visible(leads[i]), `leader in pool slot ${i} outlived its badge ${where}`);
  }
}

// boxOf is the box `place` reserved for a node or group label, given where it ended
// up. Height is passed rather than derived: a node label reserves `px + 2`, a group
// label reserves GROUP_LABEL_H at GROUP_LABEL_PX. A 1px error here reports overlaps
// the page does not have.
export function boxOf(g, node, px, h = px + 2) {
  const x = Number(node.getAttribute('x'));
  const y = Number(node.getAttribute('y'));
  return g.labelBox(x, y, g.textW(node.textContent, px), h);
}

export const overlaps = (a, b) =>
  Math.min(a.x1, b.x1) - Math.max(a.x0, b.x0) > EPS &&
  Math.min(a.y1, b.y1) - Math.max(a.y0, b.y0) > EPS;

// The frame the page is laying out against, read from the page rather than assumed:
// entering full screen changes it, and the label pass is the first thing that
// notices.
export const frameSize = p => {
  const box = p.$('#gsvg').getBoundingClientRect();
  return { width: box.width || 1200, height: box.height || 620 };
};

// onscreen is the page's own visibility test, restated: `fits` rejects a box that
// has left the viewport, so a label the page placed must be inside it. The same
// rounding slack applies — a box the page accepted can reconstruct 0.05px outside.
export const onscreen = (box, frame) =>
  box.x1 >= 2 - EPS && box.y1 >= 2 - EPS &&
  box.x0 <= frame.width - 2 + EPS && box.y0 <= frame.height - 2 + EPS;

// Where the page's own arithmetic says a label belongs, given the subject it names
// and the current view transform. `sx`/`sy` are the page's screen-space projection;
// reading them back rather than reimplementing them is what makes this a statement
// about the label's position and not about the projection.
//
// Every legal position is an (x, y) pair rather than one x and a list of y's, because a
// sequence badge's ladder moves it in both directions at once: scoring the two axes
// independently would accept a badge at one rung's x and another rung's y, which is a
// position the page cannot produce and would be off its wire.
//
// A node label has two legal positions and no others — above its dot, or, when above was
// taken, below it (`draw1`). A group label has one. A cluster label has one per rung of
// CLUSTER_RUNGS. A sequence badge has one per rung of SEQ_RUNGS, around the midpoint of
// the wire it numbers — which is a moving subject, recomputed by `drawArc` on every pan,
// zoom and drag, so a badge that stayed put is exactly the failure this scores. Its
// rungs come from the page's own `seqSpots`, for the same reason `sx`, `textW` and
// `labelBox` do: a copy of the arithmetic here would agree with a broken page.
function anchors(p, g) {
  const k = p.peek('view.k');
  const sx = p.peek('sx'), sy = p.peek('sy');
  const seqSpots = p.peek('seqSpots');
  const out = new Map();
  for (const n of p.peek('GNODES')) {
    if (!n.text) continue;
    const size = g.px[n.kind];
    out.set(n.kind + ':' + n.id, { at: [
      [sx(n.x), sy(n.y) - n.r * k - 5],
      [sx(n.x), sy(n.y) + n.r * k + size + 4],
    ] });
  }
  const GROUPS = p.peek('GROUPS');
  for (const gid of Object.keys(p.peek('groupLabels'))) {
    const grp = GROUPS[gid];
    out.set('group:' + gid, { at: [[sx(grp.cx), sy(grp.cy - grp.r) - 1]] });
  }
  const center = p.peek('center'), radius = p.peek('radius'), rungs = p.peek('CLUSTER_RUNGS');
  for (const id of p.peek('clusterIds')) {
    const cx = sx(center[id].x), cy = sy(center[id].y - radius[id]) - 2;
    out.set('cluster:' + id, { at: Array.from(rungs, r => [cx, cy + r]) });
  }
  for (const l of seqWires(p)) {
    const spots = seqSpots(l);
    // Rung zero is the wire's own midpoint, and that is the one claim the borrowed
    // arithmetic cannot make about itself.
    const mid = drawnMid(p, l);
    assert.ok(Math.abs(spots[0][0] - mid.x) <= 0.05 &&
      Math.abs(spots[0][1] - g.seqPx / 2 - mid.y) <= 0.05,
      `the ladder for ${seqId(l)} is anchored at (${spots[0][0].toFixed(1)}, ` +
      `${(spots[0][1] - g.seqPx / 2).toFixed(1)}) but the wire is drawn through ` +
      `(${mid.x.toFixed(1)}, ${mid.y.toFixed(1)})`);
    out.set('seq:' + seqId(l), { at: [...spots] });
  }
  return out;
}

// labelUnits is every label the page currently shows, with the rectangle it
// occupies — in the units the page reserves them in, which is the whole point.
//
// A cluster's title and its subtitle are one unit: `placeLabels` reserves a single
// combined box for the pair and writes the subtitle 13px under the title inside
// it. Scoring them as two would report the page colliding with itself on every
// cluster, which is a bug in the test and not in the map.
export function labelUnits(p) {
  const out = [];
  const g = geom(p);
  const at = node => ({ x: Number(node.getAttribute('x')), y: Number(node.getAttribute('y')) });
  const hullLabels = p.peek('hullLabels'), hullSubs = p.peek('hullSubs');
  for (const id of p.peek('clusterIds')) {
    const t = hullLabels[id], sub = hullSubs[id];
    if (!visible(t)) continue;
    const w = Math.max(g.textW(t.textContent, g.clusterPx), g.textW(sub.textContent, g.clusterSubPx));
    const { x, y } = at(t);
    out.push({ kind: 'cluster', id, at: { x, y }, box: g.clusterBox(x, y, w) });
  }
  const groupLabels = p.peek('groupLabels');
  for (const gid of Object.keys(groupLabels)) {
    const t = groupLabels[gid];
    if (visible(t)) {
      out.push({ kind: 'group', id: gid, at: at(t), box: boxOf(g, t, g.groupPx, g.groupH) });
    }
  }
  for (const n of p.peek('GNODES')) {
    if (n.text && visible(n.text)) {
      out.push({ kind: n.kind, id: n.id, at: at(n.text), box: boxOf(g, n.text, g.px[n.kind]) });
    }
  }
  // Sequence badges. The pool outlives a focus, so a slot past the current flow's
  // length that is still shown is a stale number left over from the last selection —
  // it is reported here under an id nothing anchors, which `assertLabels` then fails
  // on rather than quietly leaving unscored.
  const pool = p.peek('SEQ_POOL'), wires = seqWires(p);
  for (let i = 0; i < pool.length; i++) {
    if (!visible(pool[i])) continue;
    const id = i < wires.length ? seqId(wires[i]) : 'stale badge in pool slot ' + i;
    out.push({ kind: 'seq', id, at: at(pool[i]), box: boxOf(g, pool[i], g.seqPx) });
  }
  return out;
}

// assertLabels is the whole claim about the label pass, in one call, and it is four
// claims rather than two:
//
//  1. every label is on the thing it names — and a badge's ladder is anchored to the
//     midpoint of the wire as drawn, checked against the path data rather than against the
//     function that placed it;
//  2. nothing shown overlaps anything else shown;
//  3. nothing the page placed through `fits` has left the frame;
//  4. every badge the ladder moved off its wire carries a leader back to it, and every
//     badge still on its wire carries none.
//
// (1) is the one that is easy to leave out and the one that matters most. A pass that
// stops running — `placeLabels` dropped from the pan path, or from the drag path —
// leaves every label exactly where the last layout put it, which satisfies (2) and
// (3) perfectly while every name on screen points 300px away from its own dot. The
// only thing that catches that is asking where each label *should* be.
//
// Two exemptions on (2) and (3), both of them the page's stated behaviour rather than
// slack: a cluster name is the one label the page never drops, so when the rings crowd
// it climbs CLUSTER_RUNGS to get clear and, if every rung is taken, is drawn at its
// ideal position anyway — where it may overlap another cluster name, and may be off
// screen above a ring that is itself off screen. So cluster boxes are scored against
// every other kind of label, but not against each other, and not for being on screen.
// Everything else is held to all three — including a focused endpoint's sequence
// badges, whose subject is a wire's midpoint rather than a dot, and which are the one
// kind of label that can be left over from a previous selection.
export function assertLabels(p, where) {
  const units = labelUnits(p);
  const g = geom(p);
  const frame = frameSize(p);
  const want = anchors(p, g);

  for (const u of units) {
    const a = want.get(u.kind + ':' + u.id);
    assert.ok(a, `${u.kind} ${u.id} is drawn but names nothing in the layout ${where}`);
    // Coordinates are written with toFixed(1), so the comparison is to the tenth. Both
    // axes have to match the *same* legal position, or a label is being scored against a
    // place the page would never have put it.
    assert.ok(a.at.some(([x, y]) => Math.abs(u.at.x - x) <= 0.06 && Math.abs(u.at.y - y) <= 0.06),
      `${u.kind} ${u.id}'s name sits at (${u.at.x}, ${u.at.y}), which is none of ` +
      `[${a.at.map(([x, y]) => '(' + x.toFixed(1) + ', ' + y.toFixed(1) + ')').join(', ')}] ${where}` +
      ' — the label pass did not run for this view');
  }

  for (let i = 0; i < units.length; i++) {
    for (let j = i + 1; j < units.length; j++) {
      if (units[i].kind === 'cluster' && units[j].kind === 'cluster') continue;
      if (!overlaps(units[i].box, units[j].box)) continue;
      assert.fail(`${units[i].kind} ${units[i].id} overlaps ${units[j].kind} ${units[j].id} ${where}`);
    }
  }
  for (const u of units) {
    if (u.kind === 'cluster') continue;
    assert.ok(onscreen(u.box, frame), `${u.kind} ${u.id} was placed off screen ${where}`);
  }
  assertSeqLeads(p, where);
  return units;
}
