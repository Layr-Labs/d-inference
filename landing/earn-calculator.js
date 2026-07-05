/**
 * Provider earnings calculator — keep in sync with console-ui/src/app/earn/calc.ts
 *
 * Earnings model: total = usage + floor − electricity
 *   • usage — realistic throughput at healthy network demand: 60% utilization
 *     with ~2.5 concurrent requests while active (not a saturated best case).
 *   • floor — provider base reward (PR #282) by verified-memory tier, ramped by
 *     uptime, added ON TOP of usage (additive, not max).
 *   • elec — marginal inference watts over idle at a fixed US-average $/kWh.
 *
 * UI mirrors console-ui/src/app/earn: two inputs (chip + memory), a results
 * hero with a floor→estimate range, a read-only "what your Mac can run" list,
 * and a collapsible step-by-step derivation. No model selection, no
 * electricity input, no hours slider.
 */
(function () {
  const MAC_CONFIGS = [
    { macType: "MacBook Air", chip: "M1", ramOptions: [8, 16], bandwidthGBs: 68, idleWatts: 8, inferWatts: 12 },
    { macType: "MacBook Air", chip: "M2", ramOptions: [8, 16, 24], bandwidthGBs: 100, idleWatts: 8, inferWatts: 12 },
    { macType: "MacBook Air", chip: "M3", ramOptions: [8, 16, 24], bandwidthGBs: 100, idleWatts: 8, inferWatts: 12 },
    { macType: "MacBook Air", chip: "M4", ramOptions: [16, 24, 32], bandwidthGBs: 120, idleWatts: 8, inferWatts: 12 },
    { macType: "MacBook Pro", chip: "M1 Pro", ramOptions: [16, 32], bandwidthGBs: 200, idleWatts: 12, inferWatts: 30 },
    { macType: "MacBook Pro", chip: "M1 Max", ramOptions: [32, 64], bandwidthGBs: 400, idleWatts: 15, inferWatts: 40 },
    { macType: "MacBook Pro", chip: "M2 Pro", ramOptions: [16, 32], bandwidthGBs: 200, idleWatts: 12, inferWatts: 30 },
    { macType: "MacBook Pro", chip: "M2 Max", ramOptions: [32, 64, 96], bandwidthGBs: 400, idleWatts: 15, inferWatts: 40 },
    { macType: "MacBook Pro", chip: "M3", ramOptions: [8, 16, 24], bandwidthGBs: 100, idleWatts: 10, inferWatts: 20 },
    { macType: "MacBook Pro", chip: "M3 Pro", ramOptions: [18, 36], bandwidthGBs: 150, idleWatts: 15, inferWatts: 35 },
    { macType: "MacBook Pro", chip: "M3 Max", ramOptions: [36, 48, 64, 96, 128], bandwidthGBs: 400, idleWatts: 20, inferWatts: 45 },
    { macType: "MacBook Pro", chip: "M4", ramOptions: [16, 24, 32], bandwidthGBs: 120, idleWatts: 10, inferWatts: 20 },
    { macType: "MacBook Pro", chip: "M4 Pro", ramOptions: [24, 48], bandwidthGBs: 273, idleWatts: 12, inferWatts: 30 },
    { macType: "MacBook Pro", chip: "M4 Max", ramOptions: [36, 48, 64, 128], bandwidthGBs: 546, idleWatts: 20, inferWatts: 50 },
    { macType: "MacBook Pro", chip: "M5", ramOptions: [16, 24, 32], bandwidthGBs: 153, idleWatts: 10, inferWatts: 20 },
    { macType: "MacBook Pro", chip: "M5 Pro", ramOptions: [24, 48], bandwidthGBs: 300, idleWatts: 12, inferWatts: 30 },
    { macType: "MacBook Pro", chip: "M5 Max", ramOptions: [36, 48, 64, 128], bandwidthGBs: 600, idleWatts: 20, inferWatts: 50 },
    { macType: "Mac Mini", chip: "M1", ramOptions: [8, 16], bandwidthGBs: 68, idleWatts: 5, inferWatts: 10 },
    { macType: "Mac Mini", chip: "M2", ramOptions: [8, 16, 24], bandwidthGBs: 100, idleWatts: 5, inferWatts: 12 },
    { macType: "Mac Mini", chip: "M2 Pro", ramOptions: [16, 32], bandwidthGBs: 200, idleWatts: 8, inferWatts: 25 },
    { macType: "Mac Mini", chip: "M4", ramOptions: [16, 24, 32], bandwidthGBs: 120, idleWatts: 5, inferWatts: 15 },
    { macType: "Mac Mini", chip: "M4 Pro", ramOptions: [24, 48, 64], bandwidthGBs: 273, idleWatts: 8, inferWatts: 25 },
    { macType: "Mac Studio", chip: "M1 Max", ramOptions: [32, 64], bandwidthGBs: 400, idleWatts: 20, inferWatts: 60 },
    { macType: "Mac Studio", chip: "M1 Ultra", ramOptions: [64, 128], bandwidthGBs: 800, idleWatts: 30, inferWatts: 90 },
    { macType: "Mac Studio", chip: "M2 Max", ramOptions: [32, 64, 96], bandwidthGBs: 400, idleWatts: 20, inferWatts: 60 },
    { macType: "Mac Studio", chip: "M2 Ultra", ramOptions: [64, 128, 192], bandwidthGBs: 800, idleWatts: 35, inferWatts: 100 },
    { macType: "Mac Studio", chip: "M3 Ultra", ramOptions: [96, 256, 512], bandwidthGBs: 819, idleWatts: 35, inferWatts: 110 },
    { macType: "Mac Studio", chip: "M4 Max", ramOptions: [36, 48, 64, 128], bandwidthGBs: 546, idleWatts: 25, inferWatts: 65 },
    { macType: "Mac Studio", chip: "M5 Max", ramOptions: [36, 48, 64, 128], bandwidthGBs: 600, idleWatts: 25, inferWatts: 65 },
    { macType: "Mac Pro", chip: "M2 Ultra", ramOptions: [64, 128, 192], bandwidthGBs: 800, idleWatts: 40, inferWatts: 120 },
    { macType: "Mac Pro", chip: "M3 Ultra", ramOptions: [96, 256, 512], bandwidthGBs: 819, idleWatts: 40, inferWatts: 120 },
  ];

  // One option per chip: RAM options are the union across enclosures; the
  // power/bandwidth profile comes from the first enclosure listed (enclosure
  // variants differ by ~1% of the monthly total). Mirrors buildChipOptions.
  const CHIP_ORDER = [
    "M1", "M1 Pro", "M1 Max", "M1 Ultra",
    "M2", "M2 Pro", "M2 Max", "M2 Ultra",
    "M3", "M3 Pro", "M3 Max", "M3 Ultra",
    "M4", "M4 Pro", "M4 Max",
    "M5", "M5 Pro", "M5 Max",
  ];
  const CHIP_OPTIONS = (function () {
    const byChip = new Map();
    for (const c of MAC_CONFIGS) {
      const existing = byChip.get(c.chip);
      if (!existing) {
        byChip.set(c.chip, {
          chip: c.chip,
          ramOptions: [...c.ramOptions],
          bandwidthGBs: c.bandwidthGBs,
          idleWatts: c.idleWatts,
          inferWatts: c.inferWatts,
        });
      } else {
        for (const ram of c.ramOptions) {
          if (!existing.ramOptions.includes(ram)) existing.ramOptions.push(ram);
        }
      }
    }
    const options = [...byChip.values()];
    for (const opt of options) opt.ramOptions.sort((a, b) => a - b);
    options.sort((a, b) => CHIP_ORDER.indexOf(a.chip) - CHIP_ORDER.indexOf(b.chip));
    return options;
  })();

  const API_BASE = "https://api.darkbloom.dev";
  const CONSOLE_EARN_URL = "https://console.darkbloom.dev/earn";
  const DEFAULT_OUTPUT_PRICE_MICRO = 200_000;
  const DEFAULT_INPUT_PRICE_MICRO = 50_000;
  // Electricity baked in at the US average — marginal draw is ~1-2% of
  // revenue, not worth a user input. Mirrors DEFAULT_ELEC_COST_PER_KWH.
  const ELEC_COST_PER_KWH = 0.15;
  // Sustained fraction of peak memory bandwidth for a single decode stream.
  const SINGLE_STREAM_EFFICIENCY = 0.6;
  // Average concurrent requests while actively serving (engine peak is 4×).
  const CONTINUOUS_BATCH_FACTOR = 2.5;
  // Assumed network utilization (fraction of online time actively serving).
  const ASSUMED_UTILIZATION = 0.6;
  // Network-observed prompt:completion token ratio (≈3.5:1 from /v1/stats).
  const PROMPT_TO_COMPLETION_RATIO = 3.5;
  const ALWAYS_ON_HOURS = 24;

  // Provider base-reward floor by verified unified-memory tier (USD/mo).
  // Mirrors coordinator/payments/baserewards/floor.go.
  const FLOOR_TIERS = [
    { minGB: 512, label: "512GB", floorUSD: 40 },
    { minGB: 192, label: "192GB", floorUSD: 30 },
    { minGB: 128, label: "128GB", floorUSD: 26 },
    { minGB: 96, label: "96GB", floorUSD: 22 },
    { minGB: 64, label: "64GB", floorUSD: 18 },
    { minGB: 48, label: "48GB", floorUSD: 16 },
    { minGB: 32, label: "32GB", floorUSD: 12 },
    { minGB: 24, label: "24GB", floorUSD: 10 },
    { minGB: 0, label: "Under 24GB", floorUSD: 0 },
  ];
  const MIN_UPTIME_FOR_AVAIL = 0.9;

  function tierFloorUSD(memGB) {
    for (const t of FLOOR_TIERS) {
      if (memGB >= t.minGB) return t.floorUSD;
    }
    return 0;
  }
  function availFromUptime(uptimeFrac) {
    const v = (uptimeFrac - MIN_UPTIME_FOR_AVAIL) / (1 - MIN_UPTIME_FOR_AVAIL);
    if (v < 0) return 0;
    if (v > 1) return 1;
    return v;
  }
  function scaledFloorUSD(memGB, uptimeFrac, taper = 1) {
    return tierFloorUSD(memGB) * availFromUptime(uptimeFrac) * taper;
  }

  // CATALOG_MODELS is refreshed from the live coordinator catalog on load (see
  // DOMContentLoaded below). These static entries are a fallback for when the
  // API is unreachable; keep them to the currently-served lineup. Mirrors
  // console-ui/src/app/earn/calc.ts (buildCatalogModels).
  let CATALOG_MODELS = [
    { id: "gpt-oss-20b", name: "GPT-OSS 20B", minRAMGB: 24, activeParamsGB: 4, modelSizeGB: 12, outputPriceMicro: 70_000, inputPriceMicro: 14_500 },
    { id: "gemma-4-26b", name: "Gemma 4 26B", minRAMGB: 36, activeParamsGB: 4, modelSizeGB: 28, outputPriceMicro: 165_000, inputPriceMicro: 30_000 },
  ];

  // --- Live catalog → calculator model mapping (ported from console-ui) ---
  function catalogModelSizeGB(m) {
    if (m.size_gb && m.size_gb > 0) return m.size_gb;
    if (m.size_bytes && m.size_bytes > 0) return m.size_bytes / 1e9;
    const match = String(m.id || "").match(/(?:^|[^A-Za-z0-9])(\d{1,3})\s*[bB](?:[^A-Za-z0-9]|$)/);
    return match ? Number(match[1]) : 27;
  }
  function catalogActiveParamsGB(m, sizeGB) {
    const text = `${m.id || ""} ${m.architecture || ""} ${m.description || ""}`;
    const active = text.match(/A(\d{1,3}(?:\.\d+)?)B/i) || text.match(/(\d{1,3}(?:\.\d+)?)B\s+active/i);
    if (active) return Math.max(1, Math.round(Number(active[1])));
    if (/moe/i.test(text)) return Math.max(3, Math.round(sizeGB * 0.15));
    return Math.max(1, Math.round(sizeGB));
  }
  // Strip quantization / build-variant suffixes to get a base-model key, so
  // gemma-4-26b / gemma-4-26b-qat-4bit / gemma-4-26b-8bit collapse to one entry.
  function baseModelKey(id) {
    let k = String(id || "").toLowerCase().trim();
    const suffix = /-(qat|q4|q8|int4|int8|4bit|8bit|4-bit|8-bit|bf16|fp16|mxfp4|nf4|gguf|rollback|preview|beta|rc\d*)$/;
    let prev = "";
    while (k !== prev) { prev = k; k = k.replace(suffix, ""); }
    return k;
  }
  function variantPenalty(m) {
    const text = `${m.display_name || ""} ${m.id || ""}`.toLowerCase();
    let p = 0;
    if (/\(|rollback|preview|\brc\b/.test(text)) p += 100;
    if (/qat|int4|int8|fp16|bf16|mxfp4|nf4|\d\s*-?bit/.test(text)) p += 10;
    p += String(m.id || "").length * 0.01;
    return p;
  }
  function dedupeModelVariants(models) {
    const byBase = new Map();
    for (const m of models) {
      const key = baseModelKey(m.id);
      const cur = byBase.get(key);
      if (!cur || variantPenalty(m) < variantPenalty(cur)) byBase.set(key, m);
    }
    return [...byBase.values()];
  }

  function buildCatalogModels(models, pricing) {
    const outputPrices = {};
    const inputPrices = {};
    if (pricing && Array.isArray(pricing.prices)) {
      pricing.prices.forEach((p) => {
        outputPrices[p.model] = p.output_price;
        inputPrices[p.model] = p.input_price;
      });
    }
    return dedupeModelVariants(models).map((m) => {
      const size = Math.max(1, Math.round(catalogModelSizeGB(m)));
      return {
        id: m.id,
        name: m.display_name || String(m.id || "").split("/").pop() || m.id,
        minRAMGB: m.min_ram_gb || Math.ceil(size * 1.35),
        activeParamsGB: catalogActiveParamsGB(m, size),
        modelSizeGB: size,
        outputPriceMicro: outputPrices[m.id] != null ? outputPrices[m.id] : DEFAULT_OUTPUT_PRICE_MICRO,
        inputPriceMicro: inputPrices[m.id] != null ? inputPrices[m.id] : DEFAULT_INPUT_PRICE_MICRO,
      };
    });
  }

  // Per-model USAGE earnings for hoursOnlinePerDay hours/day at the demand
  // assumptions above; the base-reward floor is added separately per machine.
  function calculateModelEarnings(model, config, hoursOnlinePerDay, elecCostPerKWh) {
    // Effective decode = single-stream × avg concurrency (2.5×) × utilization (60%).
    const singleTokPerSec = (config.bandwidthGBs / model.activeParamsGB) * SINGLE_STREAM_EFFICIENCY;
    const decodeTokPerSec = singleTokPerSec * CONTINUOUS_BATCH_FACTOR * ASSUMED_UTILIZATION;
    const completionTokPerHour = decodeTokPerSec * 3600;
    const promptTokPerHour = completionTokPerHour * PROMPT_TO_COMPLETION_RATIO;
    const revenuePerHour =
      (completionTokPerHour / 1_000_000) * (model.outputPriceMicro / 1_000_000) +
      (promptTokPerHour / 1_000_000) * (model.inputPriceMicro / 1_000_000);
    const marginalWatts = config.inferWatts - config.idleWatts;
    const elecPerHour = (marginalWatts / 1000) * elecCostPerKWh * ASSUMED_UTILIZATION;
    const netPerHour = revenuePerHour - elecPerHour;
    const hoursPerMonth = hoursOnlinePerDay * 30;
    return {
      modelId: model.id,
      modelName: model.name,
      decodeTokPerSec,
      revenuePerHour,
      elecPerHour,
      netPerHour,
      monthlyRevenue: revenuePerHour * hoursPerMonth,
      monthlyElec: elecPerHour * hoursPerMonth,
      monthlyNet: netPerHour * hoursPerMonth,
      marginalWatts,
    };
  }

  // Portfolio earnings = usage PLUS the per-machine base-reward floor.
  // total = usage + floor − elec. (Single best model on the landing page.)
  function calculatePortfolioEarnings(models, config, ramGB, hoursOnlinePerDay, elecCostPerKWh) {
    if (!models.length) return null;
    const totalModelSizeGB = models.reduce((sum, model) => sum + model.modelSizeGB, 0);
    if (totalModelSizeGB > ramGB) return null;
    const hoursPerModel = hoursOnlinePerDay / models.length;
    const selectedModels = models.map((model) =>
      calculateModelEarnings(model, config, hoursPerModel, elecCostPerKWh)
    );
    const monthlyRevenue = selectedModels.reduce((sum, model) => sum + model.monthlyRevenue, 0);
    const monthlyElec = selectedModels.reduce((sum, model) => sum + model.monthlyElec, 0);
    const monthlyUsageNet = monthlyRevenue - monthlyElec;
    const uptimeFrac = Math.min(1, hoursOnlinePerDay / 24);
    const monthlyFloor = scaledFloorUSD(ramGB, uptimeFrac);
    const monthlyNet = monthlyUsageNet + monthlyFloor;
    return {
      selectedModels,
      monthlyRevenue,
      monthlyElec,
      monthlyUsageNet,
      memoryGB: ramGB,
      monthlyFloor,
      monthlyNet,
      annualNet: monthlyNet * 12,
    };
  }

  const locale = navigator.language || "en-US";
  function fmtUSD(n, decimals = 2) {
    if (n < 0) return "-$" + Math.abs(n).toFixed(decimals);
    return "$" + n.toFixed(decimals);
  }
  function fmtUSDWhole(n) {
    if (n < 0) {
      return "-$" + Math.abs(n).toLocaleString(locale, { maximumFractionDigits: 0 });
    }
    return "$" + n.toLocaleString(locale, { maximumFractionDigits: 0 });
  }

  const state = {
    chip: "M4 Max",
    ram: 48,
  };

  function chipOption(chip) {
    return CHIP_OPTIONS.find((c) => c.chip === chip) || CHIP_OPTIONS[0];
  }

  function setText(id, text) {
    const el = document.getElementById(id);
    if (el) el.textContent = text;
  }
  function setDisplay(id, show) {
    const el = document.getElementById(id);
    if (el) el.style.display = show ? "" : "none";
  }

  // Model rows: fitting models first (ranked by usage earnings), then
  // non-fitting models by how much memory they'd need. Read-only — the
  // estimate always uses the best earner automatically.
  function buildModelRows(config, ramGB) {
    const rows = CATALOG_MODELS.map((model) => {
      const fits = model.minRAMGB <= ramGB;
      return {
        model,
        fits,
        earnings: fits ? calculateModelEarnings(model, config, ALWAYS_ON_HOURS, ELEC_COST_PER_KWH) : null,
      };
    });
    rows.sort((a, b) => {
      if (a.fits !== b.fits) return a.fits ? -1 : 1;
      if (a.fits && b.fits) return (b.earnings?.monthlyNet ?? 0) - (a.earnings?.monthlyNet ?? 0);
      return a.model.minRAMGB - b.model.minRAMGB;
    });
    return rows;
  }

  function renderModelList(rows, bestId, ramGB) {
    const listEl = document.getElementById("model-list");
    if (!listEl) return;
    listEl.innerHTML = "";
    rows.forEach(({ model, fits, earnings }) => {
      const row = document.createElement("div");
      row.className = "calc-model-row" + (fits ? "" : " nofit");
      const mark = document.createElement("span");
      mark.className = "calc-model-mark " + (fits ? "ok" : "no");
      mark.textContent = fits ? "✓" : "✕";
      mark.setAttribute("aria-hidden", "true");
      const info = document.createElement("span");
      info.className = "calc-model-info";
      const name = document.createElement("span");
      name.className = "calc-model-name";
      name.textContent = model.name;
      const sub = document.createElement("span");
      sub.className = "calc-model-sub";
      sub.textContent = fits
        ? "Runs in your " + ramGB + " GB (" + model.modelSizeGB + " GB weights)"
        : "Needs " + model.minRAMGB + " GB+ of unified memory";
      info.appendChild(name);
      info.appendChild(sub);
      row.appendChild(mark);
      row.appendChild(info);
      if (fits && earnings) {
        const net = document.createElement("span");
        net.className = "calc-model-net";
        net.textContent = fmtUSDWhole(Math.max(0, earnings.monthlyNet)) + "/mo usage";
        row.appendChild(net);
      }
      if (fits && model.id === bestId) {
        const badge = document.createElement("span");
        badge.className = "calc-model-badge";
        badge.textContent = "Best earner";
        row.appendChild(badge);
      }
      listEl.appendChild(row);
    });
  }

  function renderSteps(result, config, ramGB) {
    const stepsEl = document.getElementById("calc-steps");
    if (!stepsEl) return;
    const best = result.selectedModels[0];
    const utilPct = Math.round(ASSUMED_UTILIZATION * 100);
    // Detail strings mirror console-ui AssumptionsPanel (CalcStep rows).
    const steps = [
      {
        label: "Token speed",
        detail:
          config.bandwidthGBs + " GB/s memory bandwidth ÷ " + bestActiveParams(result) +
          " GB active weights × " + SINGLE_STREAM_EFFICIENCY + " efficiency, serving " +
          CONTINUOUS_BATCH_FACTOR + " requests at once " + utilPct + "% of the time",
        value: best.decodeTokPerSec.toFixed(0) + " tok/s",
      },
      {
        label: "Usage revenue",
        detail:
          "Those tokens billed at live per-token prices, plus the prompt tokens that come with them (" +
          PROMPT_TO_COMPLETION_RATIO + ":1), around the clock",
        value: fmtUSDWhole(result.monthlyRevenue) + " /mo",
      },
      {
        label: "Electricity",
        detail:
          best.marginalWatts + "W extra draw during inference at $" + ELEC_COST_PER_KWH.toFixed(2) +
          "/kWh (US average) — only while actively serving",
        value: "−" + fmtUSD(result.monthlyElec) + " /mo",
      },
      {
        label: "Usage earnings",
        detail: "Revenue minus electricity",
        value: fmtUSDWhole(result.monthlyUsageNet) + " /mo",
      },
      {
        label: "Base reward",
        detail: ramGB + " GB memory tier, paid for staying online ≥90% of each settlement period",
        value: "+" + fmtUSDWhole(result.monthlyFloor) + " /mo",
      },
      {
        label: "Top of range",
        detail: "Usage earnings + base reward",
        value: fmtUSDWhole(result.monthlyNet) + " /mo",
        total: true,
      },
    ];

    stepsEl.innerHTML = "";
    steps.forEach((s) => {
      const row = document.createElement("div");
      row.className = "calc-step" + (s.total ? " total" : "");
      const left = document.createElement("div");
      left.className = "calc-step-info";
      const lbl = document.createElement("p");
      lbl.className = "lbl";
      lbl.textContent = s.label;
      const why = document.createElement("p");
      why.className = "why";
      why.textContent = s.detail;
      left.appendChild(lbl);
      left.appendChild(why);
      const val = document.createElement("p");
      val.className = "val";
      val.textContent = s.value;
      row.appendChild(left);
      row.appendChild(val);
      stepsEl.appendChild(row);
    });
  }

  function bestActiveParams(result) {
    const best = result.selectedModels[0];
    const catalog = CATALOG_MODELS.find((m) => m.id === best.modelId);
    return catalog ? catalog.activeParamsGB : 1;
  }

  function render() {
    const config = chipOption(state.chip);
    state.chip = config.chip;
    const ramOptions = config.ramOptions;
    const effectiveRAM = ramOptions.includes(state.ram) ? state.ram : ramOptions[ramOptions.length - 1];
    state.ram = effectiveRAM;

    // Selects
    const chipSel = document.getElementById("chip-select");
    if (chipSel && chipSel.options.length !== CHIP_OPTIONS.length) {
      chipSel.innerHTML = "";
      CHIP_OPTIONS.forEach((c) => {
        const opt = document.createElement("option");
        opt.value = c.chip;
        opt.textContent = "Apple " + c.chip;
        chipSel.appendChild(opt);
      });
    }
    if (chipSel) chipSel.value = state.chip;

    const ramSel = document.getElementById("ram-select");
    if (ramSel) {
      ramSel.innerHTML = "";
      ramOptions.forEach((ram) => {
        const opt = document.createElement("option");
        opt.value = String(ram);
        opt.textContent = ram + " GB";
        ramSel.appendChild(opt);
      });
      ramSel.value = String(effectiveRAM);
    }

    // Derivations
    const rows = buildModelRows(config, effectiveRAM);
    const bestRow = rows.find((r) => r.fits) || null;
    const bestModel = bestRow ? bestRow.model : null;
    const result = bestModel
      ? calculatePortfolioEarnings([bestModel], config, effectiveRAM, ALWAYS_ON_HOURS, ELEC_COST_PER_KWH)
      : null;
    const monthlyFloor = tierFloorUSD(effectiveRAM);
    const monthlyEstimate = result ? result.monthlyNet : monthlyFloor;
    const showRange = result !== null && monthlyEstimate > monthlyFloor;

    // Hero
    if (showRange) {
      setText("calc-hero-annual", fmtUSDWhole(monthlyFloor * 12) + " – " + fmtUSDWhole(monthlyEstimate * 12));
      setText("calc-hero-monthly", fmtUSDWhole(monthlyFloor) + " – " + fmtUSDWhole(monthlyEstimate) + " per month");
    } else {
      setText("calc-hero-annual", fmtUSDWhole(monthlyEstimate * 12));
      setText("calc-hero-monthly", fmtUSDWhole(monthlyEstimate) + " per month");
    }

    setDisplay("calc-chip-floor", monthlyFloor > 0);
    setText("calc-chip-floor-amt", fmtUSDWhole(monthlyFloor) + "/mo");
    setDisplay("calc-chip-usage", Boolean(showRange && bestModel));
    if (showRange && bestModel) {
      setText("calc-chip-usage-txt", "up to " + fmtUSDWhole(monthlyEstimate) + "/mo serving " + bestModel.name + " at healthy demand");
    }

    // No-fit state: register interest in smaller models.
    setDisplay("calc-nofit", !result);
    if (!result) {
      setText(
        "calc-nofit-msg",
        monthlyFloor > 0
          ? "No catalog model fits in " + effectiveRAM + " GB yet — you'd still earn the " + fmtUSDWhole(monthlyFloor) + "/mo base reward."
          : "No catalog model fits in " + effectiveRAM + " GB yet."
      );
    }

    renderModelList(rows, bestModel ? bestModel.id : null, effectiveRAM);

    // Assumptions accordion (hidden when nothing fits)
    setDisplay("calc-assumptions", Boolean(result));
    if (result) {
      const utilPct = Math.round(ASSUMED_UTILIZATION * 100);
      setText("calc-usage-lbl", "Usage (at " + utilPct + "% util.)");
      setText("calc-usage-val", fmtUSDWhole(result.monthlyUsageNet));
      setText("calc-floor-val", "+ " + fmtUSDWhole(result.monthlyFloor));
      setText("calc-floor-sub", effectiveRAM + " GB tier, online ≥90%");
      setText("calc-total-val", fmtUSDWhole(result.monthlyNet));
      renderSteps(result, config, effectiveRAM);
    }
  }

  function initPricingTableCurrency() {
    const fc = (n, min, max) =>
      new Intl.NumberFormat(locale, {
        style: "currency",
        currency: "USD",
        minimumFractionDigits: min ?? 2,
        maximumFractionDigits: max ?? min ?? 2,
      }).format(n);
    document.querySelectorAll(".op,.cp").forEach((el) => {
      const m = el.textContent.trim().match(/^\$?([\d.]+)$/);
      if (m) el.textContent = fc(+m[1], 2, 4);
    });
    document.querySelectorAll(".pmini .val").forEach((el) => {
      const r = el.textContent.trim();
      if (r === "0%") return;
      const m = r.match(/^\$?([\d.]+)$/);
      if (m) el.textContent = fc(+m[1], 4);
    });
    document.querySelectorAll(".vs").forEach((el) => {
      const m = el.textContent.trim().match(/([\w.]+):\s*\$?([\d.]+)/);
      if (m) el.textContent = m[1] + ": " + fc(+m[2], 4);
    });
  }

  document.addEventListener("DOMContentLoaded", () => {
    const chipSel = document.getElementById("chip-select");
    if (chipSel) {
      chipSel.addEventListener("change", () => {
        state.chip = chipSel.value;
        render();
      });
    }
    const ramSel = document.getElementById("ram-select");
    if (ramSel) {
      ramSel.addEventListener("change", () => {
        state.ram = Number(ramSel.value);
        render();
      });
    }
    const notifyBtn = document.getElementById("calc-nofit-btn");
    if (notifyBtn) {
      notifyBtn.addEventListener("click", () => {
        if (window.va) {
          window.va("event", {
            name: "small_models_interest_click",
            data: { source: "landing_earn_calc", chip: state.chip, ram_gb: state.ram },
          });
        }
      });
    }

    initPricingTableCurrency();
    render();

    // Refresh the model list from the live coordinator catalog + pricing, then
    // re-render. Falls back silently to the static CATALOG_MODELS on any error.
    if (window.fetch) {
      const getJSON = (path) =>
        fetch(API_BASE + path, { headers: { Accept: "application/json" } })
          .then((r) => (r.ok ? r.json() : Promise.reject(new Error(path + " " + r.status))));
      Promise.all([getJSON("/v1/models/catalog"), getJSON("/v1/pricing")])
        .then(([catalog, pricing]) => {
          const models = (catalog && catalog.models) || [];
          if (!models.length) return;
          const built = buildCatalogModels(models, pricing || null);
          if (built.length) {
            CATALOG_MODELS = built;
            render();
          }
        })
        .catch(() => { /* keep the static fallback CATALOG_MODELS */ });
    }
  });
})();
