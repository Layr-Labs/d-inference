/**
 * Landing-page provider calculator. Market math lives in
 * earn-calculator-core.js and mirrors console-ui/src/app/earn/calc.ts.
 */
(function () {
  "use strict";

  const Core = window.DarkbloomEarnings;
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
  const CHIP_ORDER = [
    "M1", "M1 Pro", "M1 Max", "M1 Ultra",
    "M2", "M2 Pro", "M2 Max", "M2 Ultra",
    "M3", "M3 Pro", "M3 Max", "M3 Ultra",
    "M4", "M4 Pro", "M4 Max",
    "M5", "M5 Pro", "M5 Max",
  ];
  const CHIP_OPTIONS = (function () {
    const byChip = new Map();
    MAC_CONFIGS.forEach(function (config) {
      const existing = byChip.get(config.chip);
      if (!existing) {
        byChip.set(config.chip, {
          chip: config.chip,
          ramOptions: config.ramOptions.slice(),
          bandwidthGBs: config.bandwidthGBs,
          idleWatts: config.idleWatts,
          inferWatts: config.inferWatts,
        });
        return;
      }
      config.ramOptions.forEach(function (ram) {
        if (!existing.ramOptions.includes(ram)) existing.ramOptions.push(ram);
      });
    });
    const options = Array.from(byChip.values());
    options.forEach(function (option) {
      option.ramOptions.sort(function (a, b) { return a - b; });
    });
    options.sort(function (a, b) {
      return CHIP_ORDER.indexOf(a.chip) - CHIP_ORDER.indexOf(b.chip);
    });
    return options;
  })();

  const API_BASE = "https://api.darkbloom.dev";
  const ELECTRICITY_USD_PER_KWH = 0.15;
  const locale = navigator.language || "en-US";
  const state = {
    chip: "M4 Max",
    ram: 48,
    marketState: "loading",
    market: null,
  };

  function fmtUSD(value, decimals) {
    const places = decimals === undefined ? 2 : decimals;
    const absolute = Math.abs(value).toLocaleString(locale, {
      minimumFractionDigits: places,
      maximumFractionDigits: places,
    });
    return value < 0 ? "-$" + absolute : "$" + absolute;
  }

  function fmtTokens(value) {
    return Math.round(value).toLocaleString(locale);
  }

  function chipOption(chip) {
    return CHIP_OPTIONS.find(function (option) {
      return option.chip === chip;
    }) || CHIP_OPTIONS[0];
  }

  function setText(id, text) {
    const element = document.getElementById(id);
    if (element) element.textContent = text;
  }

  function setDisplay(id, show) {
    const element = document.getElementById(id);
    if (element) element.style.display = show ? "" : "none";
  }

  function renderSelectors(config, effectiveRAM) {
    const chipSelect = document.getElementById("chip-select");
    if (chipSelect && chipSelect.options.length !== CHIP_OPTIONS.length) {
      chipSelect.innerHTML = "";
      CHIP_OPTIONS.forEach(function (option) {
        const item = document.createElement("option");
        item.value = option.chip;
        item.textContent = "Apple " + option.chip;
        chipSelect.appendChild(item);
      });
    }
    if (chipSelect) chipSelect.value = config.chip;

    const ramSelect = document.getElementById("ram-select");
    if (ramSelect) {
      ramSelect.innerHTML = "";
      config.ramOptions.forEach(function (ram) {
        const item = document.createElement("option");
        item.value = String(ram);
        item.textContent = ram + " GB";
        ramSelect.appendChild(item);
      });
      ramSelect.value = String(effectiveRAM);
    }
  }

  function renderModelMessage(message) {
    const list = document.getElementById("model-list");
    if (!list) return;
    list.innerHTML = "";
    const status = document.createElement("div");
    status.className = "calc-model-row";
    status.textContent = message;
    list.appendChild(status);
  }

  function renderModelList(rows, bestID, ramGB) {
    const list = document.getElementById("model-list");
    if (!list) return;
    list.innerHTML = "";
    rows.forEach(function (entry) {
      const model = entry.model;
      const row = document.createElement("div");
      row.className = "calc-model-row" + (entry.fits ? "" : " nofit");

      const mark = document.createElement("span");
      mark.className = "calc-model-mark " + (entry.fits ? "ok" : "no");
      mark.textContent = entry.fits ? "✓" : "✕";
      mark.setAttribute("aria-hidden", "true");

      const info = document.createElement("span");
      info.className = "calc-model-info";
      const name = document.createElement("span");
      name.className = "calc-model-name";
      name.textContent = model.display_name;
      const sub = document.createElement("span");
      sub.className = "calc-model-sub";
      sub.textContent = entry.fits
        ? "Runs in your " + ramGB + " GB (" +
          (model.size_gb < 10 ? model.size_gb.toFixed(1) : model.size_gb.toFixed(0)) +
          " GB weights)"
        : "Needs " + model.min_ram_gb + " GB+ of unified memory";
      info.appendChild(name);
      info.appendChild(sub);
      row.appendChild(mark);
      row.appendChild(info);

      if (entry.fits) {
        const amount = document.createElement("span");
        amount.className = "calc-model-net";
        amount.textContent = entry.estimate
          ? fmtUSD(entry.estimate.workPayoutUSD) + "/mo work"
          : Core.unavailableReasonLabel(model.unavailable_reason);
        row.appendChild(amount);
      }
      if (entry.estimate && model.id === bestID) {
        const badge = document.createElement("span");
        badge.className = "calc-model-badge";
        badge.textContent = "Best estimate";
        row.appendChild(badge);
      }
      list.appendChild(row);
    });
  }

  function appendStep(container, label, detail, value, total) {
    const row = document.createElement("div");
    row.className = "calc-step" + (total ? " total" : "");
    const left = document.createElement("div");
    left.className = "calc-step-info";
    const heading = document.createElement("p");
    heading.className = "lbl";
    heading.textContent = label;
    const why = document.createElement("p");
    why.className = "why";
    why.textContent = detail;
    const amount = document.createElement("p");
    amount.className = "val";
    amount.textContent = value;
    left.appendChild(heading);
    left.appendChild(why);
    row.appendChild(left);
    row.appendChild(amount);
    container.appendChild(row);
  }

  function renderSteps(result, config, ramGB, market) {
    const steps = document.getElementById("calc-steps");
    if (!steps) return;
    const model = result.model;
    const policy = market.base_rewards;
    const uptimePercent = Math.round(policy.min_uptime_fraction * 100);
    steps.innerHTML = "";
    appendStep(
      steps,
      "Trailing settled payout pool",
      model.paid_jobs.toLocaleString(locale) + " paid jobs and " +
        fmtTokens(model.paid_tokens) + " paid tokens in the fixed 30-day window",
      fmtUSD(result.workPoolUSD) + " / 30d",
    );
    appendStep(
      steps,
      "Competing live capacity",
      model.provider_supply + " eligible providers; " +
        model.aggregate_memory_bandwidth_gbps.toFixed(0) + " GB/s aggregate reported bandwidth",
      model.aggregate_tps.toFixed(1) + " tok/s",
    );
    appendStep(
      steps,
      "Candidate capacity",
      model.benchmark_tps.toFixed(1) + " observed tok/s ÷ " +
        model.benchmark_memory_bandwidth_gbps.toFixed(0) + " GB/s × this Mac's " +
        config.bandwidthGBs + " GB/s",
      result.candidateTPS.toFixed(1) + " tok/s",
    );
    appendStep(
      steps,
      "Candidate work payout",
      fmtUSD(result.workPoolUSD) + " × c/(S+c), a " +
        (result.candidateShare * 100).toFixed(2) + "% capacity share",
      fmtUSD(result.workPayoutUSD) + " /mo",
    );
    appendStep(
      steps,
      "Electricity",
      config.idleWatts + "W online idle for 720h plus " +
        Math.max(0, config.inferWatts - config.idleWatts) + "W workload draw for " +
        result.activeHours.toFixed(2) + "h at $" + ELECTRICITY_USD_PER_KWH.toFixed(2) + "/kWh",
      "−" + fmtUSD(result.electricityUSD) + " /mo",
    );
    appendStep(
      steps,
      "Base reward maximum",
      policy.enabled
        ? ramGB + " GB tier at full availability; ≥" + uptimePercent +
          "% uptime eligibility, then fixed fleet-pool allocation"
        : "Base rewards are currently disabled",
      "+" + fmtUSD(result.baseRewardPotentialUSD) + " /mo",
    );
    appendStep(
      steps,
      "Estimated net",
      "Candidate work payout + base reward maximum − idle and workload electricity",
      fmtUSD(result.monthlyNetUSD) + " /mo",
      true,
    );
  }

  function renderBaseRewardPolicy(marketState, market) {
    const table = document.getElementById("calc-floor-table");
    const rows = document.getElementById("calc-floor-rows");
    if (marketState === "loading") {
      setText("calc-base-intro", "Loading configured reward policy…");
      setDisplay("calc-floor-table", false);
      return;
    }
    if (marketState !== "ready" || !market) {
      setText("calc-base-intro", "Reward policy unavailable.");
      setDisplay("calc-floor-table", false);
      return;
    }
    const policy = market.base_rewards;
    setText(
      "calc-base-intro",
      "Maximum per-machine tiers at full availability, before eligibility and allocation. " +
        "All eligible machines share one fixed " +
        fmtUSD(policy.monthly_pool_micro_usd / 1e6) +
        " monthly pool; tier amounts are not guaranteed.",
    );
    setText(
      "calc-base-eligibility",
      "Requires attestation, health, and at least " +
        Math.round(policy.min_uptime_fraction * 100) +
        "% uptime; full tier credit requires full availability.",
    );
    setText(
      "calc-base-enabled",
      policy.enabled
        ? "The program is enabled, subject to eligibility and the fleet-wide pool cap."
        : "The program is currently disabled; the table does not create a payout.",
    );
    if (!rows || !table) return;
    rows.innerHTML = "";
    const tiers = policy.tiers.slice().sort(function (a, b) {
      return b.min_ram_gb - a.min_ram_gb;
    });
    tiers.forEach(function (tier) {
      const monthly = tier.monthly_micro_usd / 1e6;
      const row = document.createElement("tr");
      [tier.min_ram_gb + "GB+", fmtUSD(monthly, 0), fmtUSD(monthly * 12, 0)].forEach(
        function (text) {
          const cell = document.createElement("td");
          cell.textContent = text;
          row.appendChild(cell);
        },
      );
      rows.appendChild(row);
    });
    const under = document.createElement("tr");
    const minimum = tiers.length ? tiers[tiers.length - 1].min_ram_gb : 0;
    ["Under " + minimum + "GB", "—", "—"].forEach(function (text) {
      const cell = document.createElement("td");
      cell.textContent = text;
      under.appendChild(cell);
    });
    rows.appendChild(under);
    setDisplay("calc-floor-table", true);
  }

  function renderUnavailable(detail) {
    setText("calc-hero-annual", "Estimate unavailable");
    setText("calc-hero-monthly", detail);
    setDisplay("calc-hero-unit", false);
    setDisplay("calc-chip-floor", false);
    setDisplay("calc-chip-usage", false);
    setDisplay("calc-assumptions", false);
    setDisplay("calc-nofit", false);
  }

  function render() {
    const config = chipOption(state.chip);
    state.chip = config.chip;
    const ramOptions = config.ramOptions;
    const effectiveRAM = ramOptions.includes(state.ram)
      ? state.ram
      : ramOptions[ramOptions.length - 1];
    state.ram = effectiveRAM;
    renderSelectors(config, effectiveRAM);
    renderBaseRewardPolicy(state.marketState, state.market);

    if (state.marketState === "loading") {
      setText("calc-hero-annual", "…");
      setText("calc-hero-monthly", "Loading the trailing market window…");
      setDisplay("calc-hero-unit", false);
      setDisplay("calc-chip-floor", false);
      setDisplay("calc-chip-usage", false);
      setDisplay("calc-assumptions", false);
      setDisplay("calc-nofit", false);
      renderModelMessage("Loading trailing market data…");
      return;
    }
    if (state.marketState !== "ready" || !state.market) {
      renderUnavailable("Trailing settled-payout market data could not be loaded.");
      renderModelMessage("Estimate unavailable");
      return;
    }

    const rows = Core.buildModelRows(
      state.market,
      config,
      effectiveRAM,
      ELECTRICITY_USD_PER_KWH,
    );
    const best = rows.find(function (entry) {
      return entry.fits && entry.estimate;
    }) || null;
    const hasFittingModel = rows.some(function (entry) {
      return entry.fits;
    });
    renderModelList(rows, best ? best.model.id : null, effectiveRAM);

    if (!best) {
      renderUnavailable(
        hasFittingModel
          ? "No fitting model has both settled payout and live supply benchmark data."
          : "No active public model fits in " + effectiveRAM + " GB.",
      );
      setDisplay("calc-nofit", !hasFittingModel);
      if (!hasFittingModel) {
        setText("calc-nofit-msg", "No active public model fits in " + effectiveRAM + " GB.");
      }
      return;
    }

    const result = best.estimate;
    setText("calc-hero-annual", fmtUSD(result.annualNetUSD));
    setText("calc-hero-monthly", fmtUSD(result.monthlyNetUSD) + " per month after electricity");
    setDisplay("calc-hero-unit", true);
    setDisplay("calc-nofit", false);
    setDisplay("calc-chip-usage", true);
    setText(
      "calc-chip-usage-txt",
      fmtUSD(result.workPayoutUSD) + "/mo candidate share for " + best.model.display_name,
    );
    setDisplay("calc-chip-floor", result.baseRewardPotentialUSD > 0);
    setText("calc-chip-floor-amt", "up to " + fmtUSD(result.baseRewardPotentialUSD) + "/mo");

    setDisplay("calc-assumptions", true);
    setText("calc-usage-lbl", "Candidate work share");
    setText("calc-usage-val", fmtUSD(result.workPayoutUSD));
    setText("calc-floor-val", "+ " + fmtUSD(result.baseRewardPotentialUSD));
    setText("calc-floor-sub", "eligibility- and pool-capped maximum");
    setText("calc-total-val", fmtUSD(result.monthlyNetUSD));
    setText(
      "calc-audit",
      "Audit: " + fmtUSD(state.market.audit.modeled_work_micro_usd / 1e6) +
        " modeled + " + fmtUSD(state.market.audit.unattributed_work_micro_usd / 1e6) +
        " unattributed = " +
        fmtUSD(state.market.audit.total_settled_work_micro_usd / 1e6) +
        " total settled work.",
    );
    renderSteps(result, config, effectiveRAM, state.market);
  }

  function initPricingTableCurrency() {
    const format = function (number, min, max) {
      return new Intl.NumberFormat(locale, {
        style: "currency",
        currency: "USD",
        minimumFractionDigits: min === undefined ? 2 : min,
        maximumFractionDigits: max === undefined ? (min === undefined ? 2 : min) : max,
      }).format(number);
    };
    document.querySelectorAll(".op,.cp").forEach(function (element) {
      const match = element.textContent.trim().match(/^\$?([\d.]+)$/);
      if (match) element.textContent = format(Number(match[1]), 2, 4);
    });
    document.querySelectorAll(".pmini .val").forEach(function (element) {
      const raw = element.textContent.trim();
      if (raw === "0%") return;
      const match = raw.match(/^\$?([\d.]+)$/);
      if (match) element.textContent = format(Number(match[1]), 4);
    });
  }

  document.addEventListener("DOMContentLoaded", function () {
    const chipSelect = document.getElementById("chip-select");
    if (chipSelect) {
      chipSelect.addEventListener("change", function () {
        state.chip = chipSelect.value;
        render();
      });
    }
    const ramSelect = document.getElementById("ram-select");
    if (ramSelect) {
      ramSelect.addEventListener("change", function () {
        state.ram = Number(ramSelect.value);
        render();
      });
    }
    const notifyButton = document.getElementById("calc-nofit-btn");
    if (notifyButton) {
      notifyButton.addEventListener("click", function () {
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
    if (!Core || !window.fetch) {
      state.marketState = "unavailable";
      render();
      return;
    }
    fetch(API_BASE + "/v1/earnings/market", {
      headers: { Accept: "application/json" },
    })
      .then(function (response) {
        if (!response.ok) throw new Error("earnings market " + response.status);
        return response.json();
      })
      .then(function (payload) {
        state.market = Core.parseMarket(payload);
        state.marketState = "ready";
        render();
      })
      .catch(function () {
        state.market = null;
        state.marketState = "unavailable";
        render();
      });
  });
})();
