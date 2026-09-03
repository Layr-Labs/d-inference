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
});

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
// A node label has two legal positions and no others — above its dot, or, when above
// was taken, below it (`draw1`). A group label has one. A cluster label has one per
// rung of CLUSTER_RUNGS.
function anchors(p, g) {
  const k = p.peek('view.k');
  const sx = p.peek('sx'), sy = p.peek('sy');
  const out = new Map();
  for (const n of p.peek('GNODES')) {
    if (!n.text) continue;
    const size = g.px[n.kind];
    out.set(n.kind + ':' + n.id, {
      x: sx(n.x),
      y: [sy(n.y) - n.r * k - 5, sy(n.y) + n.r * k + size + 4],
    });
  }
  const GROUPS = p.peek('GROUPS');
  for (const gid of Object.keys(p.peek('groupLabels'))) {
    const grp = GROUPS[gid];
    out.set('group:' + gid, { x: sx(grp.cx), y: [sy(grp.cy - grp.r) - 1] });
  }
  const center = p.peek('center'), radius = p.peek('radius'), rungs = p.peek('CLUSTER_RUNGS');
  for (const id of p.peek('clusterIds')) {
    const cy = sy(center[id].y - radius[id]) - 2;
    out.set('cluster:' + id, { x: sx(center[id].x), y: Array.from(rungs, r => cy + r) });
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
  return out;
}

// assertLabels is the whole claim about the label pass, in one call, and it is three
// claims rather than two:
//
//  1. every label is on the thing it names;
//  2. nothing shown overlaps anything else shown;
//  3. nothing the page placed through `fits` has left the frame.
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
// Everything else is held to all three.
export function assertLabels(p, where) {
  const units = labelUnits(p);
  const g = geom(p);
  const frame = frameSize(p);
  const want = anchors(p, g);

  for (const u of units) {
    const a = want.get(u.kind + ':' + u.id);
    assert.ok(a, `${u.kind} ${u.id} is drawn but names nothing in the layout ${where}`);
    // Coordinates are written with toFixed(1), so the comparison is to the tenth.
    assert.ok(Math.abs(u.at.x - a.x) <= 0.06,
      `${u.kind} ${u.id}'s name sits at x=${u.at.x} while its subject is at x=${a.x.toFixed(1)} ${where}` +
      ' — the label pass did not run for this view');
    assert.ok(a.y.some(y => Math.abs(u.at.y - y) <= 0.06),
      `${u.kind} ${u.id}'s name sits at y=${u.at.y}, which is none of ` +
      `[${a.y.map(y => y.toFixed(1)).join(', ')}] ${where}` +
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
  return units;
}
