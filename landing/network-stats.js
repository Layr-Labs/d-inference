/* Live network strip.
 *
 * Reads the coordinator's public /v1/stats endpoint and fills the
 * "Live network" tiles with real figures. Degrades gracefully:
 *   - Nodes / tokens / requests always render (these fields are long-lived).
 *   - The "Network power" tile is derived from the coordinator's
 *     active_power_watts when present, else summed from the per-provider
 *     hardware in providers[]; it stays hidden only when neither is available.
 *
 * Base URL is overridable for local testing:
 *   index.html?coord=http://localhost:PORT
 */
(function () {
  "use strict";

  var STATS_API =
    new URLSearchParams(location.search).get("coord") ||
    "https://api.darkbloom.dev";

  // ---- Formatting helpers -------------------------------------------------

  function formatNum(n) {
    if (n >= 1e9) return (n / 1e9).toFixed(1) + "B";
    if (n >= 1e6) return (n / 1e6).toFixed(1) + "M";
    if (n >= 1e3) return (n / 1e3).toFixed(1) + "K";
    return String(n);
  }

  function formatPower(w) {
    if (!w || w <= 0) return null;
    // Strip a trailing ".0" so this matches console-ui's formatPower exactly
    // (e.g. "1 kW", not "1.0 kW").
    var trim = function (s) { return s.replace(/\.0$/, ""); };
    if (w < 1e3) return Math.round(w) + " W";
    if (w < 1e6) return trim(w < 1e5 ? (w / 1e3).toFixed(1) : String(Math.round(w / 1e3))) + " kW";
    if (w < 1e9) return trim(w < 1e8 ? (w / 1e6).toFixed(1) : String(Math.round(w / 1e6))) + " MW";
    return trim((w / 1e9).toFixed(1)) + " GW";
  }

  // ---- Network power estimate (mirrors coordinator EstimateMachineWatts) ----
  // Realistic Apple Silicon max sustained wall draw under load, by family/tier.
  var POWER_TABLE = {
    M1: { Base: 40, Pro: 60, Max: 115, Ultra: 215 },
    M2: { Base: 50, Pro: 75, Max: 140, Ultra: 280 },
    M3: { Base: 50, Pro: 75, Max: 150, Ultra: 290 },
    M4: { Base: 65, Pro: 100, Max: 170, Ultra: 300 },
    M5: { Base: 70, Pro: 105, Max: 180, Ultra: 310 },
  };

  function machineWatts(family, tier, gpuCores) {
    var fam = (family || "").trim().toUpperCase();
    var t = (tier || "").trim().toLowerCase();
    var norm = t === "ultra" ? "Ultra" : t === "max" ? "Max" : t === "pro" ? "Pro" : "Base";
    if (POWER_TABLE[fam]) return POWER_TABLE[fam][norm];
    var cores = gpuCores || 0;
    return cores <= 0 ? 30 : Math.max(30, 30 + 3.5 * cores);
  }

  // Prefer the coordinator-provided active_power_watts; else sum per-provider
  // estimates over the online providers already in the response.
  function activePowerWatts(d) {
    if (isFiniteNum(d.active_power_watts) && d.active_power_watts > 0) {
      return d.active_power_watts;
    }
    var ps = d.providers || [];
    var sum = 0;
    for (var i = 0; i < ps.length; i++) {
      sum += machineWatts(ps[i].chip_family, ps[i].chip_tier, ps[i].gpu_cores);
    }
    return sum;
  }

  // Exposed for unit checking / debugging.
  if (typeof window !== "undefined") {
    window.DarkbloomNetStats = { formatNum: formatNum, formatPower: formatPower };
  }

  // ---- DOM wiring ---------------------------------------------------------

  function byId(id) {
    return typeof document !== "undefined" ? document.getElementById(id) : null;
  }

  function setText(id, value) {
    var el = byId(id);
    if (el && value != null) el.textContent = value;
  }

  function show(id) {
    var el = byId(id);
    if (el) el.style.display = "";
  }

  function isFiniteNum(v) {
    return typeof v === "number" && isFinite(v);
  }

  function render(d) {
    if (!d) return;

    // Always-present fields.
    if (isFiniteNum(d.active_providers)) {
      setText("ns-nodes", formatNum(d.active_providers));
    }
    if (isFiniteNum(d.total_tokens)) {
      setText("ns-tokens", formatNum(d.total_tokens));
    }
    if (isFiniteNum(d.total_requests)) {
      setText("ns-requests", formatNum(d.total_requests));
    }

    // Network power — derived from the coordinator field if present, else from
    // the per-provider hardware already in the response.
    var power = formatPower(activePowerWatts(d));
    if (power) {
      setText("ns-power", power);
      show("ns-power-cell");
    }
  }

  if (typeof window !== "undefined" && window.fetch) {
    fetch(STATS_API + "/v1/stats", { headers: { Accept: "application/json" } })
      .then(function (r) {
        return r.ok ? r.json() : null;
      })
      .then(function (d) {
        render(d);
      })
      .catch(function () {
        /* offline / API down — leave the "—" placeholders in place */
      });
  }
})();
