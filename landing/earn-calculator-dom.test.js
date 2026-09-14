const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const Core = require("./earn-calculator-core.js");
const source = fs.readFileSync(process.env.LANDING_CALCULATOR_SCRIPT || path.join(__dirname, "earn-calculator.js"), "utf8");

// Only the DOM operations used by the calculator are needed; no browser,
// network, dependencies, or implementation-private functions are exposed.
function element() {
  return {
    children: [], style: {}, value: "", textContent: "", listeners: new Map(),
    appendChild(child) { this.children.push(child); },
    setAttribute() {},
    addEventListener(name, handler) { this.listeners.set(name, handler); },
    get options() { return this.children; },
    set innerHTML(value) { assert.equal(value, ""); this.children = []; },
  };
}
function mount(core = Core) {
  const nodes = new Map();
  const events = [];
  let ready;
  const document = {
    getElementById(id) {
      if (!nodes.has(id)) nodes.set(id, element());
      return nodes.get(id);
    },
    createElement: element,
    addEventListener(name, handler) { assert.equal(name, "DOMContentLoaded"); ready = handler; },
  };
  vm.runInNewContext(source, { window: { DarkbloomEarnings: core, va: (...args) => events.push(args) }, document, navigator: { language: "en-US" }, Intl });
  ready();
  return {
    get: document.getElementById,
    events,
    change(id, value, name = "change") {
      const node = document.getElementById(id);
      node.value = value;
      node.listeners.get(name)();
    },
  };
}
function configure(ui) {
  ui.change("mac-type-select", "MacBook Pro");
  ui.change("chip-select", "M5 Max (40-core GPU)");
  ui.change("ram-select", "64");
}

test("selector cascade preserves readiness, memory options, and estimates", () => {
  const ui = mount();
  assert.equal(ui.get("chip-select").disabled, true);
  assert.equal(ui.get("ram-select").disabled, true);
  assert.equal(ui.get("calc-results").style.display, "none");
  configure(ui);
  assert.deepEqual(ui.get("ram-select").options.map(option => option.value), ["", "48", "64", "128"]);
  assert.equal(ui.get("calc-results").style.display, "");
  assert.equal(ui.get("calc-empty").style.display, "none");
  assert.match(ui.get("calc-hero-primary").textContent, /^\$/);
  const original = ui.get("calc-hero-primary").textContent;
  ui.change("calc-duty-input", "50", "input");
  assert.notEqual(ui.get("calc-hero-primary").textContent, original);
  assert.match(ui.get("calc-hero-annualized").textContent, /50% duty cycle$/);
  ui.change("mac-type-select", "Mac Mini");
  assert.equal(ui.get("chip-select").value, "");
  assert.equal(ui.get("ram-select").value, "");
  assert.equal(ui.get("ram-select").disabled, true);
});

test("both interest buttons retain event names and selected hardware", () => {
  const ui = mount();
  configure(ui);
  ui.change("calc-nofit-btn", "", "click");
  ui.change("calc-readiness-btn", "", "click");
  assert.equal(ui.events.length, 2);
  const events = JSON.parse(JSON.stringify(ui.events));
  assert.deepEqual(events.map(event => event[1].name), ["small_models_interest_click", "production_readiness_interest_click"]);
  for (const [method, event] of events) {
    assert.equal(method, "event");
    assert.deepEqual(event.data, { source: "landing_earn_calc", mac_type: "MacBook Pro", chip: "M5 Max (40-core GPU)", ram_gb: 64 });
  }
  ui.change("mac-type-select", "Mac Mini");
  ui.change("calc-nofit-btn", "", "click");
  assert.equal(ui.events.length, 2);
});

test("missing core remains an empty usable selector without an estimate", () => {
  const ui = mount(null);
  assert.equal(ui.get("mac-type-select").options.length, 1);
  assert.equal(ui.get("calc-empty").style.display, "");
  assert.equal(ui.get("calc-results").style.display, "none");
});
