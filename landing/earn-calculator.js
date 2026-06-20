/**
 * Provider earnings calculator — keep in sync with console-ui/src/app/earn/calc.ts
 *
 * Earnings model: total = usage + floor − electricity
 *   • usage — realistic throughput at 80% utilization, crediting continuous
 *     batching at a quality-preserving 4× (not the old 16× ceiling, which
 *     overstated earnings).
 *   • floor — provider base reward (PR #282) by verified-memory tier, ramped by
 *     uptime, added ON TOP of usage (additive, not max).
 *   • elec — marginal inference watts over idle, scaled by utilization.
 */
(function () {
  const MAC_TYPES = ["MacBook Air", "MacBook Pro", "Mac Mini", "Mac Studio", "Mac Pro"];

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

  const API_BASE = "https://api.darkbloom.dev";
  const DEFAULT_OUTPUT_PRICE_MICRO = 200_000;
  const DEFAULT_INPUT_PRICE_MICRO = 50_000;
  // Sustained fraction of peak memory bandwidth for a single decode stream.
  const SINGLE_STREAM_EFFICIENCY = 0.6;
  // Continuous-batching gain over single-stream at quality-preserving
  // concurrency (capped at 4×, not the theoretical 16× ceiling).
  const CONTINUOUS_BATCH_FACTOR = 4;
  // Assumed network utilization (fraction of online time actively serving).
  const ASSUMED_UTILIZATION = 0.8;
  // Network-observed prompt:completion token ratio (≈3.5:1 from /v1/stats).
  const PROMPT_TO_COMPLETION_RATIO = 3.5;

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
    { id: "gpt-oss-20b", name: "GPT-OSS 20B", minRAMGB: 24, activeParamsGB: 4, modelSizeGB: 12, outputPriceMicro: 70_000, inputPriceMicro: 14_500, demandNote: "Uses the live coordinator catalog and current/default per-token pricing." },
    { id: "gemma-4-26b", name: "Gemma 4 26B", minRAMGB: 36, activeParamsGB: 4, modelSizeGB: 28, outputPriceMicro: 165_000, inputPriceMicro: 30_000, demandNote: "Uses the live coordinator catalog and current/default per-token pricing." },
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
        demandNote: "Uses the live coordinator catalog and current/default per-token pricing.",
        activeParamsGB: catalogActiveParamsGB(m, size),
        modelSizeGB: size,
        outputPriceMicro: outputPrices[m.id] != null ? outputPrices[m.id] : DEFAULT_OUTPUT_PRICE_MICRO,
        inputPriceMicro: inputPrices[m.id] != null ? inputPrices[m.id] : DEFAULT_INPUT_PRICE_MICRO,
      };
    });
  }

  const REGION_ELEC = { US: 0.15, CA: 0.12, GB: 0.28, DE: 0.35, FR: 0.21, AU: 0.28, JP: 0.26, IN: 0.08, SG: 0.18, KR: 0.11 };

  function detectRegionElec() {
    try {
      const parts = (navigator.language || "en-US").split("-");
      if (parts.length >= 2) {
        const code = parts[parts.length - 1].toUpperCase();
        if (REGION_ELEC[code] != null) return REGION_ELEC[code];
      }
    } catch (_) { /* ignore */ }
    return 0.15;
  }

  // Per-model USAGE earnings at 100% utilization for hoursOnlinePerDay hours/day.
  // Single-stream throughput (no batch multiplier); floor is added separately.
  function calculateModelEarnings(model, config, hoursOnlinePerDay, elecCostPerKWh) {
    // Effective decode = single-stream × continuous batch (4×) × utilization (80%).
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
    const monthlyRevenue = revenuePerHour * hoursPerMonth;
    const monthlyElec = elecPerHour * hoursPerMonth;
    const monthlyNet = netPerHour * hoursPerMonth;
    const elecPercent = monthlyRevenue > 0 ? (monthlyElec / monthlyRevenue) * 100 : 0;
    return {
      modelId: model.id,
      modelName: model.name,
      decodeTokPerSec,
      revenuePerHour,
      elecPerHour,
      netPerHour,
      monthlyRevenue,
      monthlyElec,
      monthlyNet,
      elecPercent,
    };
  }

  // Portfolio earnings = Σ per-model usage (models share active hours) PLUS the
  // per-machine base-reward floor, minus electricity. total = usage + floor − elec.
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
    const activeHoursPerMonth = Math.max(1, hoursOnlinePerDay * 30);
    return {
      modelName: models.length === 1 ? models[0].name : `${models.length} models selected`,
      selectedModels,
      selectedModelCount: models.length,
      totalModelSizeGB,
      hoursPerModel,
      decodeTokPerSec: selectedModels.reduce((sum, model) => sum + model.decodeTokPerSec, 0) / selectedModels.length,
      monthlyRevenue,
      monthlyElec,
      monthlyUsageNet,
      revenuePerHour: monthlyRevenue / activeHoursPerMonth,
      elecPerHour: monthlyElec / activeHoursPerMonth,
      netPerHour: monthlyUsageNet / activeHoursPerMonth,
      elecPercent: monthlyRevenue > 0 ? (monthlyElec / monthlyRevenue) * 100 : 0,
      memoryGB: ramGB,
      uptimeFrac,
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
    macType: "MacBook Pro",
    chip: "M4 Max",
    ram: 48,
    hours: 24,
    elecCost: detectRegionElec(),
    selectedModelIds: [],
  };

  function chipsForMacType(macType) {
    const chips = [];
    for (const c of MAC_CONFIGS) {
      if (c.macType === macType && !chips.includes(c.chip)) chips.push(c.chip);
    }
    return chips;
  }

  function configFor(macType, chip) {
    return MAC_CONFIGS.find((c) => c.macType === macType && c.chip === chip);
  }

  function pill(label, selected, onClick) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = label;
    Object.assign(btn.style, {
      padding: "7px 14px",
      borderRadius: "4px",
      fontSize: "12px",
      fontWeight: selected ? "500" : "400",
      fontFamily: "var(--font-mono)",
      cursor: "pointer",
      transition: "all .15s",
      border: "1px solid",
      outline: "none",
      letterSpacing: "0.02em",
      background: selected ? "var(--black)" : "var(--white)",
      color: selected ? "var(--white)" : "var(--grey-03)",
      borderColor: selected ? "var(--black)" : "var(--grey-01)",
    });
    btn.onmouseenter = () => {
      if (!selected) btn.style.borderColor = "var(--grey-03)";
    };
    btn.onmouseleave = () => {
      if (!selected) btn.style.borderColor = "var(--grey-01)";
    };
    btn.onclick = onClick;
    return btn;
  }

  function rankedModels(config, ramGB, elecCost) {
    const eligible = CATALOG_MODELS.filter((m) => m.minRAMGB <= ramGB);
    const results = eligible.map((m) => calculateModelEarnings(m, config, 24, elecCost));
    results.sort((a, b) => b.monthlyNet - a.monthlyNet);
    return results;
  }

  function render() {
    const chips = chipsForMacType(state.macType);
    const effectiveChip = chips.includes(state.chip) ? state.chip : chips[chips.length - 1];
    state.chip = effectiveChip;

    const config = configFor(state.macType, effectiveChip);
    if (!config) return;

    const ramOptions = config.ramOptions;
    const effectiveRAM = ramOptions.includes(state.ram) ? state.ram : ramOptions[ramOptions.length - 1];
    state.ram = effectiveRAM;

    const elecInput = document.getElementById("elec-cost");
    const elecCost = parseFloat(elecInput?.value) || 0;

    const ranked = rankedModels(config, effectiveRAM, elecCost);
    const bestId = ranked.length > 0 ? ranked[0].modelId : null;
    const eligibleIds = new Set(ranked.map((m) => m.modelId));
    const validSelectedIds = state.selectedModelIds.filter((id) => eligibleIds.has(id));
    const effectiveModelIds = validSelectedIds.length > 0 ? validSelectedIds : bestId ? [bestId] : [];
    const selectedCatalogModels = effectiveModelIds
      .map((id) => CATALOG_MODELS.find((m) => m.id === id))
      .filter(Boolean);
    const selectedModelSizeGB = selectedCatalogModels.reduce((sum, model) => sum + model.modelSizeGB, 0);

    const hint = document.getElementById("model-hint");
    if (hint) {
      if (ranked.length === 0) {
        hint.textContent = "No compatible catalog model for this memory configuration";
      } else if (state.selectedModelIds.length > 0) {
        hint.textContent = `${selectedCatalogModels.length} model${selectedCatalogModels.length === 1 ? "" : "s"} selected (${selectedModelSizeGB} GB weights). Active hours are shared.`;
      } else {
        hint.textContent = "Auto-selected: most profitable model. Select more models if they fit in memory.";
      }
    }

    const macSel = document.getElementById("mac-sel");
    macSel.innerHTML = "";
    MAC_TYPES.forEach((mt) => {
      macSel.appendChild(
        pill(mt, state.macType === mt, () => {
          state.macType = mt;
          state.selectedModelIds = [];
          const nextChips = chipsForMacType(mt);
          state.chip = nextChips[nextChips.length - 1];
          render();
        })
      );
    });

    const chipSel = document.getElementById("chip-sel");
    chipSel.innerHTML = "";
    chips.forEach((chip) => {
      chipSel.appendChild(
        pill(chip, effectiveChip === chip, () => {
          state.chip = chip;
          state.selectedModelIds = [];
          render();
        })
      );
    });

    const ramSel = document.getElementById("ram-sel");
    ramSel.innerHTML = "";
    ramOptions.forEach((ram) => {
      ramSel.appendChild(
        pill(ram + " GB", effectiveRAM === ram, () => {
          state.ram = ram;
          state.selectedModelIds = [];
          render();
        })
      );
    });

    const modelList = document.getElementById("model-list");
    modelList.innerHTML = "";
    ranked.forEach((m) => {
      const isSelected = effectiveModelIds.includes(m.modelId);
      const isBest = m.modelId === bestId;
      const catalog = CATALOG_MODELS.find((c) => c.id === m.modelId);
      const canAdd =
        state.selectedModelIds.length === 0 ||
        isSelected ||
        selectedModelSizeGB + (catalog?.modelSizeGB || 0) <= effectiveRAM;
      const row = document.createElement("button");
      row.type = "button";
      row.title = canAdd ? "" : "Not enough memory to add this model; clicking will switch to it instead";
      row.className =
        "calc-model-row" +
        (isSelected ? " on" : "") +
        (m.monthlyNet < 0 ? " unprofitable" : "");
      row.innerHTML =
        '<span class="calc-radio"></span>' +
        '<span class="calc-model-name"></span>' +
        '<span class="calc-model-net"></span>';
      row.querySelector(".calc-model-name").textContent = m.modelName;
      const netEl = row.querySelector(".calc-model-net");
      netEl.textContent = fmtUSD(m.monthlyNet) + "/mo usage";
      netEl.className = "calc-model-net " + (m.monthlyNet >= 0 ? "pos" : "neg");
      if (isBest && m.monthlyNet > 0) {
        const badge = document.createElement("span");
        badge.className = "calc-model-badge";
        badge.textContent = "Best model";
        row.appendChild(badge);
      }
      row.onclick = () => {
        if (validSelectedIds.length === 0) {
          state.selectedModelIds = [m.modelId];
          render();
          return;
        }
        const base = validSelectedIds.length > 0 ? validSelectedIds : bestId ? [bestId] : [];
        if (base.includes(m.modelId)) {
          const next = base.filter((id) => id !== m.modelId);
          state.selectedModelIds = next.length > 0 ? next : base;
        } else if (canAdd) {
          state.selectedModelIds = [...base, m.modelId];
        } else {
          state.selectedModelIds = [m.modelId];
        }
        render();
      };
      modelList.appendChild(row);
      if (isSelected && catalog?.demandNote) {
        const note = document.createElement("div");
        note.className = "calc-model-note";
        note.textContent =
          catalog.demandNote +
          (m.monthlyNet < 0
            ? " Usage revenue is below electricity on your hardware — the base reward still applies."
            : "");
        modelList.appendChild(note);
      }
    });

    const result = calculatePortfolioEarnings(selectedCatalogModels, config, effectiveRAM, state.hours, elecCost);

    const emptyEl = document.getElementById("calc-empty");
    const resultsEl = document.getElementById("calc-results");
    if (!result) {
      emptyEl.style.display = "block";
      resultsEl.style.display = "none";
      return;
    }
    emptyEl.style.display = "none";
    resultsEl.style.display = "block";

    const uptimePct = 100; // fixed: always-on, 100% utilization assumed
    const setText = (id, text) => {
      const el = document.getElementById(id);
      if (el) el.textContent = text;
    };

    setText("res-model-name", result.modelName);
    setText("res-monthly-net", fmtUSDWhole(result.monthlyNet));
    setText("res-annual-net", fmtUSDWhole(result.annualNet) + " / year");
    setText("res-usage", fmtUSD(result.monthlyUsageNet));
    setText("res-floor", "+ " + fmtUSD(result.monthlyFloor));
    setText("res-total", fmtUSD(result.monthlyNet));
    setText("res-decode", result.decodeTokPerSec.toFixed(1) + " tok/s");
    setText("res-revenue", fmtUSD(result.monthlyRevenue));
    setText("res-elec", "-" + fmtUSD(result.monthlyElec));
    setText("res-elec-pct", result.elecPercent.toFixed(1) + "%");
    setText("res-rev-hr", fmtUSD(result.revenuePerHour, 4));
    setText("res-elec-hr", fmtUSD(result.elecPerHour, 4));
    setText("res-net-hr", fmtUSD(result.netPerHour, 4));

    const floorNote = document.getElementById("res-floor-note");
    if (floorNote) {
      floorNote.textContent =
        "Includes the " + effectiveRAM + "GB base reward at " + uptimePct + "% uptime.";
    }
  }

  function initPricingTableCurrency() {
    const locale = navigator.language || "en-US";
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
    const elecInput = document.getElementById("elec-cost");
    if (elecInput) {
      elecInput.value = String(state.elecCost);
      elecInput.addEventListener("input", render);
    }
    // Utilization & hours are fixed at 100% / always-on — no slider.
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
            state.selectedModelIds = [];
            render();
          }
        })
        .catch(() => { /* keep the static fallback CATALOG_MODELS */ });
    }
  });
})();
