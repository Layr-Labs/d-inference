// The timeline's control half, in its own file because the map is complete without
// it: everything above draws one revision, and this is the part that lets a reader
// walk them. Concatenated after page.js and before page.boot.js — the ordering is a
// contract, stated in render.go, because `TL` below is a `const` initialized at load
// and the bootstrap's first `draw()` reads it.
// ---------------------------------------------------------------------------
// The timeline, second half: the control.
//
// The artifact is delta-encoded, so the reader's position is replayed rather than
// looked up: one mutable set of live routes, nodes and wires, stepped forward by a
// point's additions and removals or backward by undoing them. A drag of four
// hundred commits costs the sum of four hundred small deltas, which is what makes
// dragging feel like dragging rather than like four hundred rebuilds.
//
// The timeline is inert until it is touched. Loading the page draws the map at its
// own revision, exactly as it does with no history embedded; the first drag,
// keypress or play engages it, and from then on the point governs the picture —
// including at the last point, where "what did the newest commit change" is a
// question worth being able to ask.
// ---------------------------------------------------------------------------
const TL = (() => {
  if (!HISTORY) return null;
  const P = HISTORY.snapshots, R = HISTORY.routes, N = HISTORY.nodes, W = HISTORY.links;
  const routes = new Set(), nodes = new Set(), modes = new Map();
  const wkey = w => wireKey(R[w.r].key, N[w.n].id);
  let i = -1, engaged = false;
  // Removals are applied before additions in both directions, because a wire whose
  // access mode changed is encoded as one removed and one added — the same pair of
  // endpoints twice — and doing it the other way round would delete the survivor.
  const fwd = p => {
    for (const x of p.rd || []) routes.delete(R[x].key);
    for (const x of p.nd || []) nodes.delete(N[x].id);
    for (const x of p.ld || []) modes.delete(wkey(W[x]));
    for (const x of p.ra || []) routes.add(R[x].key);
    for (const x of p.na || []) nodes.add(N[x].id);
    for (const x of p.la || []) modes.set(wkey(W[x]), W[x].m);
  };
  const back = p => {
    for (const x of p.ra || []) routes.delete(R[x].key);
    for (const x of p.na || []) nodes.delete(N[x].id);
    for (const x of p.la || []) modes.delete(wkey(W[x]));
    for (const x of p.rd || []) routes.add(R[x].key);
    for (const x of p.nd || []) nodes.add(N[x].id);
    for (const x of p.ld || []) modes.set(wkey(W[x]), W[x].m);
  };
  // What this commit took away, kept as its own sets: the picture ghosts them, which
  // is the difference between "this endpoint is not here" and "this commit removed
  // this endpoint".
  let goneAt = -1, goneRoutes = new Set(), goneNodes = new Set(), goneWires = new Set();
  const ghosts = () => {
    if (goneAt === i) return;
    goneAt = i;
    const p = P[i];
    goneRoutes = new Set((p.rd || []).map(x => R[x].key));
    goneNodes = new Set((p.nd || []).map(x => N[x].id));
    // A wire whose mode merely changed is not a wire this commit removed: the pair
    // is still live, and ghosting it would draw the same association twice.
    goneWires = new Set((p.ld || []).map(x => wkey(W[x])).filter(k => !modes.has(k)));
  };
  const names = (list, of) => (list || []).map(of);
  const failed = HISTORY.failed || [];
  return {
    count: P.length,
    last: P.length - 1,
    head: HISTORY.head || '',
    // Commits the walk could not extract, so they are not on the axis at all. A count
    // rather than a list: what a reader needs is to know the axis has holes in it, and
    // which commit failed to type-check under today's toolchain is a fact about the
    // build and not about the service.
    failed: failed.length,
    get i() { return i; },
    get engaged() { return engaged; },
    point: () => P[i] || P[P.length - 1],
    prev: () => P[i - 1] || null,
    live: n => (n.kind === 'ep' ? routes.has(n.name) : nodes.has(n.dep)),
    wire: l => modes.has(l.key),
    modeOf: l => modes.get(l.key),
    goneRoute: n => (ghosts(), n.kind === 'ep' ? goneRoutes.has(n.name) : goneNodes.has(n.dep)),
    goneWire: l => (ghosts(), goneWires.has(l.key)),
    added: () => {
      const p = P[i];
      return { routes: names(p.ra, x => R[x].key), nodes: names(p.na, x => N[x].id),
        wires: (p.la || []).length };
    },
    removed: () => {
      const p = P[i];
      return { routes: names(p.rd, x => R[x].key), nodes: names(p.nd, x => N[x].id),
        wires: (p.ld || []).length };
    },
    go(n, byReader) {
      if (byReader) engaged = true;
      n = Math.max(0, Math.min(P.length - 1, n | 0));
      while (i < n) fwd(P[++i]);
      while (i > n) back(P[i--]);
      return i;
    },
    // Reset puts the page back to being a map of one revision, which is what the
    // rest of the button does to every other choice the reader made.
    disengage() { engaged = false; this.go(P.length - 1); },
  };
})();
// What the picture holds at the reader's position. Untouched, that is the head
// revision itself: a historical-only entity is no part of the map, and the map is
// authoritative about its own commit — so the page a reader lands on is identical
// whether or not a history was built beside it.
const tlLive = n => !TL || !TL.engaged ? !n.hist : TL.live(n);
const tlWire = l => !TL || !TL.engaged ? !l.hist : TL.wire(l);
// A node's edges as the head revision has them, which is what the panels and the focus
// readout must say however far back the slider is.
//
// Every revision's wires are pushed into the same `n.links` — that is what makes one
// layout serve the whole walk — so the raw list is the union and not any one commit's.
// Reading it unfiltered had `mdm.commands`, which nothing reaches, telling a reader that
// `GET /ws/provider` reaches it, with a working link to that endpoint: a categorical
// derived claim inverted by a wire that was deleted months ago, on a page whose premise
// is that the graph is authoritative. Deliberately not `tlWire`: these read-outs describe
// the head revision at every slider position, unlike the graph, which is the one part of
// the page that travels.
const headLinks = n => n.links.filter(l => !l.hist);
// A wire's colour is the mode the commit derived, not the mode the head does: an
// endpoint that used to only read the state it now writes is a change in the
// picture, and the picture is where it should be visible.
function tlMode(l) {
  const want = (TL.engaged && TL.modeOf(l)) || l.mode0;
  if (want === l.mode) return;
  l.mode = want;
  l.node.setAttribute('stroke', modeColor[want] || 'var(--dim)');
  l.node.setAttribute('data-topo', linkTopo(l));
  l.arrowKey = null; // its head is the wrong colour now
}

const TIME = {
  timer: null,
  // Fast enough to read a shape moving, slow enough to see a commit: ~7 points a
  // second over four hundred commits is a minute of history.
  every: 140,
};
function tlPlay(on) {
  if (TIME.timer) { clearInterval(TIME.timer); TIME.timer = null; }
  if (on) {
    if (TL.i >= TL.last) TL.go(0, true);
    TIME.timer = setInterval(() => {
      if (TL.i >= TL.last) { tlPlay(false); tlSync(); return; }
      tlGo(TL.i + 1);
    }, TIME.every);
  }
  const btn = document.getElementById('gtplay');
  btn.textContent = on ? '❙❙' : '▶';
  btn.title = on ? 'Pause' : 'Play the history forward (Space)';
}
function tlGo(n) {
  TL.go(n, true);
  // A focus is a claim about a node the reader can see. Sliding past the commit
  // that node was added in would leave the claim pointing at nothing, shadowing the
  // whole picture in the name of something not drawn.
  const f = state.focus ? gById[state.focus] : null;
  if (f && !tlLive(f)) state.focus = null;
  draw();
}
// One point's readout: where the reader is, what the service was, and what this
// commit did to it.
function tlSync() {
  const bar = document.getElementById('gtime');
  if (!TL) return;
  bar.hidden = false;
  const p = TL.point(), prev = TL.prev();
  const range = document.getElementById('gtrange');
  range.max = String(TL.last);
  range.value = String(TL.i);
  document.body.classList.toggle('travelling', TL.engaged && TL.i < TL.last);
  document.getElementById('gtdate').textContent = p.date;
  document.getElementById('gtpos').textContent = '· commit ' + (TL.i + 1) + ' of ' + TL.count;
  const rev = document.getElementById('gtrev');
  rev.textContent = p.rev.slice(0, 9);
  if (COMMIT) rev.href = COMMIT + p.rev; else rev.removeAttribute('href');
  document.getElementById('gtcounts').textContent =
    p.counts.routes + ' endpoints · ' + p.counts.nodes + ' dependencies · ' +
    p.counts.links + ' wires · ' + p.tables + ' tables';
  const delta = document.getElementById('gtdelta');
  delta.textContent = '';
  if (prev) {
    const d = (now, was, one) => {
      const n = now - was;
      if (!n) return;
      const s = el('span', n > 0 ? 'up' : 'down', (n > 0 ? '+' : '−') + Math.abs(n) + ' ' + one);
      delta.append(s, document.createTextNode(' '));
    };
    d(p.counts.routes, prev.counts.routes, 'endpoints');
    d(p.counts.nodes, prev.counts.nodes, 'dependencies');
    d(p.counts.links, prev.counts.links, 'wires');
  }
  document.getElementById('gtsubject').textContent = p.subject;
  tlDiff();
  tlNote(p);
}
// The chips. A commit's own diff, as things a reader can click on: an endpoint or a
// node that survived to the head revision selects it, and one that did not says so
// rather than pretending to be selectable.
const TL_CHIPS = 14;
function tlDiff() {
  const host = document.getElementById('gtdiff');
  host.textContent = '';
  const add = TL.added(), del = TL.removed();
  if (!add.routes.length && !add.nodes.length && !del.routes.length && !del.nodes.length &&
      !add.wires && !del.wires) {
    host.append(el('span', 'gtq', 'This commit changed the coordinator without changing its shape.'));
    return;
  }
  let room = TL_CHIPS;
  const put = (name, sign, isRoute) => {
    if (room-- <= 0) return;
    const c = el('span', 'chip gt' + (sign === '+' ? 'add' : 'del'));
    c.append(el('b', null, sign));
    c.append(el('span', 'mono', isRoute ? name : shortName(name)));
    const alive = isRoute ? !!gByEp[name] && !gByEp[name].hist : !!DATA.nodes[name];
    if (alive) {
      c.style.cursor = 'pointer';
      c.onclick = () => { isRoute ? openEndpoint(name) : selectDep(name); };
      c.title = (sign === '+' ? 'Added by this commit' : 'Removed by this commit') +
        '. Click to select it in the inventory below.';
    } else {
      c.classList.add('gtdead');
      c.title = (sign === '+' ? 'Added by this commit' : 'Removed by this commit') +
        '. Not part of the head revision, so the inventory below has nothing to say about it.';
    }
    host.append(c);
  };
  for (const r of del.routes) put(r, '−', true);
  for (const r of add.routes) put(r, '+', true);
  for (const n of del.nodes) put(n, '−', false);
  for (const n of add.nodes) put(n, '+', false);
  const over = add.routes.length + add.nodes.length + del.routes.length + del.nodes.length - TL_CHIPS;
  if (over > 0) host.append(el('span', 'gtq', '+' + over + ' more'));
  if (add.wires || del.wires) {
    host.append(el('span', 'gtq', (del.wires ? '−' + del.wires + ' ' : '') +
      (add.wires ? '+' + add.wires + ' ' : '') + 'wires, including every wire whose ' +
      'access mode changed'));
  }
}
// What a reader has to be told rather than shown: that the point is drawn with today's
// overlay, that everything under the graph is the head revision, and where the axis
// itself is incomplete.
function tlNote(p) {
  const note = document.getElementById('gtnote');
  const parts = [];
  if (!TL.engaged) {
    parts.push('Drag the slider to walk the coordinator’s history. The graph moves; ' +
      'the tables, panels and counts below always describe the head revision.');
  } else {
    parts.push('Derived by running today’s extractor over this commit, and named by ' +
      'today’s overlay.');
    const f = p.fidelity || {};
    if (f.unmapped) {
      parts.push(f.unmapped + ' fields this commit reached have no node in the overlay — ' +
        'state whose subsystem was later deleted, so its curated entry went with it. ' +
        'They are missing from this point, not from that commit.');
    }
    if (TL.i < TL.last) {
      parts.push('Dashed amber is what this commit removed. ' +
        'The tables below still describe the head revision.');
    }
  }
  // A hole in the axis, stated. The walk type-checks every commit with today's
  // toolchain, so an old one can fail to load for reasons that have nothing to do with
  // whether it worked at the time; such a commit is dropped rather than guessed at. It
  // is worth one sentence because of where its changes go: a dropped commit's diff is
  // not lost, it is attributed to the next commit that did extract, so a reader who
  // finds two unrelated changes on one point has an explanation for it.
  if (TL.failed) {
    const one = TL.failed === 1;
    parts.push(TL.failed + (one ? ' commit in this range could not be type-checked with ' +
      'today’s toolchain and is not on the axis; what it changed shows up on the next ' +
      'point instead.' : ' commits in this range could not be type-checked with today’s ' +
      'toolchain and are not on the axis; what they changed shows up on the next point ' +
      'that extracted.'));
  }
  if (TL.head && DATA.revision && TL.head !== DATA.revision) {
    parts.push('This timeline was built at ' + TL.head.slice(0, 9) + ' and the map at ' +
      (DATA.revision || '').slice(0, 9) + ', so the last point and the map may differ.');
  }
  note.textContent = parts.join(' ');
}

// Full screen makes the graph the whole window, and the graph is exactly what the
// timeline moves — a slider left behind on the scrolled page underneath would be a
// control for something the reader can no longer see. So the bar travels with it, as
// a strip along the bottom above the zoom buttons, and comes back to its place in the
// flow on the way out. Same element either way: the range's value, the play timer and
// the reader's position all survive the move because nothing is rebuilt.
function tlDock(inFull) {
  const bar = document.getElementById('gtime');
  bar.classList.toggle('gtover', inFull);
  if (inFull) graphBox.append(bar);
  else document.querySelector('.stage').insertBefore(bar, document.getElementById('gkey'));
}
