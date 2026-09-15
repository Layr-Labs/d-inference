// The orchestrator: one `draw`, the control wiring, and the bootstrap that runs it.
// Last of the three script parts, so every declaration it reaches — the drawing
// passes above and `TL` beside them — has already been initialized by the time its
// top-level statements execute.
function draw() {
  styleGraph();
  drawSchema();
  drawBoundaries();
  drawRoutes();
  drawEdges();
  drawFks();
  if (TL) tlSync();
  document.getElementById('topo').textContent = topoFingerprint();
}

document.getElementById('q').oninput = e => { state.q = e.target.value.trim().toLowerCase(); draw(); };
document.getElementById('ns').onchange = e => { state.ns = e.target.value; draw(); };
document.getElementById('auth').onchange = e => { state.auth = e.target.value; draw(); };
document.getElementById('dep').onchange = e => {
  state.dep = e.target.value;
  state.table = tableFor(state.dep) ? state.dep : null;
  draw();
};
document.getElementById('mode').onchange = e => { state.mode = e.target.value; draw(); };
document.getElementById('ont').onchange = e => { state.ont = e.target.value; draw(); };
for (const b of document.querySelectorAll('.seg button')) {
  b.onclick = () => setView(b.dataset.view);
}
// Reset clears what the reader chose to look at. It leaves the provenance view
// alone: that is not a filter on the system, it is a statement about who wrote
// the page, and it stays where it was put.
document.getElementById('reset').onclick = () => {
  Object.assign(state, { q: '', ns: '', auth: '', dep: '', mode: '', ont: '',
    open: null, table: null, wide: false, focus: null });
  for (const id of ['q', 'ns', 'auth', 'dep', 'mode', 'ont']) document.getElementById(id).value = '';
  location.hash = '';
  // The timeline is one of the things the reader chose to look at, so Reset returns
  // the page to being a map of one revision — the same thing it does to every filter.
  if (TL) { tlPlay(false); TL.disengage(); }
  fit();
  draw();
};
document.getElementById('gfocusclear').onclick = clearFocus;
addEventListener('keydown', e => { if (e.key === 'Escape' && state.focus) clearFocus(); });
addEventListener('resize', () => { sizeStage(); fit(); });

// The timeline's controls. Wired only when a history was embedded: without one the bar
// stays hidden and there is nothing here to drive.
if (TL) {
  const range = document.getElementById('gtrange');
  range.max = String(TL.last);
  range.value = String(TL.last);
  // `input`, not `change`: a slider that only reports on release is a slider you
  // cannot watch a shape move with, which is the whole of what this is for.
  range.oninput = () => { tlPlay(false); tlGo(Number(range.value)); };
  document.getElementById('gtplay').onclick = () => { tlPlay(!TIME.timer); };
  document.getElementById('gtnow').onclick = () => { tlPlay(false); tlGo(TL.last); };
  // Stepping one commit at a time is how the diff is actually read, so it gets keys —
  // but only when the reader is not typing into the search box, and never over the
  // slider itself, which does its own stepping and would otherwise move twice.
  //
  // Buttons and links are in that list for Space, which is how a keyboard reader presses
  // the control they have tabbed to. Taking it would mean every button on the page stops
  // working the moment a history is embedded, and silently — the reader has no way to
  // know that the thing swallowing their keypress is a slider somewhere below.
  const OWNS_KEYS = { INPUT: 1, SELECT: 1, TEXTAREA: 1, BUTTON: 1, A: 1, SUMMARY: 1 };
  addEventListener('keydown', e => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const t = e.target;
    if (t && (OWNS_KEYS[t.tagName] || t.isContentEditable)) return;
    if (e.key === 'ArrowLeft') { tlPlay(false); tlGo(TL.i - 1); e.preventDefault(); }
    else if (e.key === 'ArrowRight') { tlPlay(false); tlGo(TL.i + 1); e.preventDefault(); }
    else if (e.key === ' ') { tlPlay(!TIME.timer); e.preventDefault(); }
  });
  // Start at the head revision: engaged is false, so this is the map, and the bar is
  // a readout of the commit the map is already of.
  TL.go(TL.last);
}

document.getElementById('withheld').textContent =
  WITHHELD.labels + ' node labels, ' + WITHHELD.descriptions + ' endpoint descriptions, ' +
  WITHHELD.fields + ' node prose fields, ' + WITHHELD.roles + ' actors, ' + WITHHELD.creds +
  ' credentials';

if (location.hash.length > 1) state.open = decodeURIComponent(location.hash.slice(1));
// Markers first: the legend below and the wires above both reference them by id.
buildMarkers();
drawLegend();
buildGraph();
setView('all');
