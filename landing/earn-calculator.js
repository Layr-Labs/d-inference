/**
 * Landing-page provider calculator. Projection math lives in
 * earn-calculator-core.js and mirrors console-ui/src/app/earn/calc.ts.
 */
(function () {
  "use strict";

  const Core = window.DarkbloomEarnings;
  const MIN_PROVIDER_MEMORY_GB = Core ? Core.MIN_PROVIDER_MEMORY_GB : 48;
  const PROVIDER_HARDWARE_OPTIONS =
    Core && Array.isArray(Core.PROVIDER_HARDWARE_OPTIONS)
      ? Core.PROVIDER_HARDWARE_OPTIONS
      : [];
  const locale = navigator.language || "en-US";
  const MAC_TYPES = PROVIDER_HARDWARE_OPTIONS.reduce(function (types, option) {
    if (!types.includes(option.macType)) types.push(option.macType);
    return types;
  }, []);
  const state = {
    macType: "",
    chip: "",
    ram: null,
    dutyCyclePercent: Core ? Core.DEFAULT_DUTY_CYCLE_PERCENT : 5,
    catalogModels: Core ? Core.CALCULATOR_MODELS : [],
  };

  function fmtUSD(value, decimals) {
    const places = decimals === undefined ? 2 : decimals;
    const absolute = Math.abs(value).toLocaleString(locale, {
      minimumFractionDigits: places,
      maximumFractionDigits: places,
    });
    return value < 0 ? "-$" + absolute : "$" + absolute;
  }

  function fmtCompactTokens(value) {
    return new Intl.NumberFormat(locale, {
      notation: "compact",
      maximumFractionDigits: 2,
    }).format(value);
  }

  function hardwareOption(macType, chip) {
    return PROVIDER_HARDWARE_OPTIONS.find(function (option) {
      return option.macType === macType && option.chip === chip;
    }) || null;
  }

  function setText(id, value) {
    const element = document.getElementById(id);
    if (element) element.textContent = value;
  }

  function setDisplay(id, show) {
    const element = document.getElementById(id);
    if (element) element.style.display = show ? "" : "none";
  }

  function appendPlaceholder(select, label) {
    const item = document.createElement("option");
    item.value = "";
    item.textContent = label;
    item.disabled = true;
    select.appendChild(item);
  }

  function renderSelectors(config, isProductionReady) {
    const macTypeSelect = document.getElementById("mac-type-select");
    if (macTypeSelect && macTypeSelect.options.length !== MAC_TYPES.length + 1) {
      macTypeSelect.innerHTML = "";
      appendPlaceholder(macTypeSelect, "Select model");
      MAC_TYPES.forEach(function (macType) {
        const item = document.createElement("option");
        item.value = macType;
        item.textContent = macType;
        macTypeSelect.appendChild(item);
      });
    }
    if (macTypeSelect) macTypeSelect.value = state.macType;

    const chipSelect = document.getElementById("chip-select");
    if (chipSelect) {
      chipSelect.innerHTML = "";
      appendPlaceholder(chipSelect, "Select chip");
      PROVIDER_HARDWARE_OPTIONS.filter(function (option) {
        return option.macType === state.macType;
      }).forEach(function (option) {
        const item = document.createElement("option");
        item.value = option.chip;
        item.textContent = option.chip;
        chipSelect.appendChild(item);
      });
      chipSelect.disabled = !state.macType;
      chipSelect.value = state.chip;
    }

    const ramSelect = document.getElementById("ram-select");
    if (ramSelect) {
      ramSelect.innerHTML = "";
      appendPlaceholder(ramSelect, "Select memory");
      (config ? config.ramOptions : []).forEach(function (ram) {
        const item = document.createElement("option");
        item.value = String(ram);
        item.textContent = ram + " GB";
        ramSelect.appendChild(item);
      });
      ramSelect.disabled = !config;
      ramSelect.value = state.ram === null ? "" : String(state.ram);
    }

    setDisplay("calc-duty", isProductionReady);
    setText("calc-duty-value", state.dutyCyclePercent + "%");
    const dutyInput = document.getElementById("calc-duty-input");
    if (dutyInput) dutyInput.value = String(state.dutyCyclePercent);
  }

  function renderModelMessage(message) {
    const list = document.getElementById("model-list");
    if (!list) return;
    list.innerHTML = "";
    const status = document.createElement("li");
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
      const row = document.createElement("li");
      row.className = "calc-model-row" + (entry.fits ? "" : " nofit");

      const mark = document.createElement("span");
      mark.className = "calc-model-mark " + (entry.fits ? "ok" : "no");
      mark.textContent = entry.fits ? "✓" : "✕";
      mark.setAttribute("aria-hidden", "true");

      const info = document.createElement("span");
      info.className = "calc-model-info";
      const name = document.createElement("span");
      name.className = "calc-model-name";
      name.textContent = model.displayName;
      const sub = document.createElement("span");
      sub.className = "calc-model-sub";
      sub.textContent = entry.fits
        ? "Fits in your " + ramGB + " GB (" +
          (model.sizeGB < 10 ? model.sizeGB.toFixed(1) : model.sizeGB.toFixed(0)) +
          " GB of model weights)"
        : "Requires at least " + model.minRAMGB + " GB of unified memory";
      info.appendChild(name);
      info.appendChild(sub);
      row.appendChild(mark);
      row.appendChild(info);

      if (entry.fits) {
        const amount = document.createElement("span");
        amount.className = "calc-model-net";
        amount.textContent = entry.estimate
          ? fmtUSD(entry.estimate.monthlyRevenueUSD) + "/mo estimated earning"
          : "Earning estimate unavailable";
        row.appendChild(amount);
      }
      if (entry.estimate && model.id === bestID) {
        const badge = document.createElement("span");
        badge.className = "calc-model-badge";
        badge.textContent = "Best current estimate";
        row.appendChild(badge);
      }
      list.appendChild(row);
    });
  }

  function appendStep(container, label, detail, value) {
    const row = document.createElement("div");
    row.className = "calc-step";
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

  function renderFlow(result, config) {
    const flow = document.getElementById("calc-flow");
    if (!flow) return;
    const model = result.model;
    const activeBillions = model.activeParameterCount / 1e9;
    flow.innerHTML = "";
    appendStep(
      flow,
      "1. Model that fits",
      model.minRAMGB + " GB minimum memory · " +
        model.sizeGB.toFixed(1) + " GB model weights",
      model.displayName,
    );
    appendStep(
      flow,
      "2. Chip memory bandwidth",
      config.chip + " peak unified-memory bandwidth",
      config.bandwidthGBs + " GB/s",
    );
    appendStep(
      flow,
      "3. Single-stream decode speed",
      config.bandwidthGBs + " GB/s × " +
        (Core.DECODE_BANDWIDTH_EFFICIENCY * 100).toFixed(0) + "% ÷ " +
        result.activeWeightGBPerToken.toFixed(2) + " GB/token (" +
        activeBillions.toFixed(1) + "B active params)",
      result.decodeTokensPerSecond.toFixed(1) + " tok/s",
    );
    appendStep(
      flow,
      "4. Duty cycle",
      (result.activeSecondsPerMonth / 3600).toFixed(0) + " active hours per 30-day month",
      state.dutyCyclePercent + "%",
    );
    appendStep(
      flow,
      "5. Output capacity",
      "One sequence at a time, with no batching",
      fmtCompactTokens(result.outputTokensPerMonth) + " tokens/mo",
    );
    appendStep(
      flow,
      "6. OpenRouter output pricing",
      "Applied to " + fmtCompactTokens(result.outputTokensPerMonth) +
        " output tokens per month",
      fmtUSD(result.outputPriceUSDPerMillion, 3) + " / 1M tokens",
    );
  }

  function renderUnavailable(detail) {
    setText("calc-hero-primary", "Estimate unavailable");
    setText("calc-hero-annualized", detail);
    setDisplay("calc-hero-unit", false);
    setDisplay("calc-flow-section", false);
    setDisplay("calc-nofit", false);
  }

  function render() {
    const config = hardwareOption(state.macType, state.chip);
    const effectiveRAM = config && config.ramOptions.includes(state.ram) ? state.ram : 0;
    const isConfigured = Boolean(config && effectiveRAM > 0);
    const isProductionReady = isConfigured && effectiveRAM >= MIN_PROVIDER_MEMORY_GB;
    renderSelectors(config, isProductionReady);
    setDisplay("calc-results", isProductionReady);
    setDisplay("calc-empty", !isConfigured);
    setDisplay("calc-readiness", isConfigured && !isProductionReady);
    if (!isConfigured) return;
    if (!isProductionReady) {
      setText(
        "calc-readiness-detail",
        "Have a smaller Mac? We'd still love to hear from you. Register your interest " +
          "to help us plan support as we quickly expand Darkbloom to more machines.",
      );
      return;
    }

    if (!state.catalogModels.length) {
      renderUnavailable("The current model catalog could not be loaded.");
      renderModelMessage("Estimate unavailable");
      return;
    }

    const rows = state.catalogModels.map(function (model) {
      const fits = model.minRAMGB <= effectiveRAM;
      return {
        model: model,
        fits: fits,
        estimate: fits
          ? Core.calculateCapacityRevenue(model, config, effectiveRAM, state.dutyCyclePercent)
          : null,
      };
    }).sort(function (a, b) {
      if (a.fits !== b.fits) return a.fits ? -1 : 1;
      return (b.estimate ? b.estimate.monthlyRevenueUSD : 0) -
        (a.estimate ? a.estimate.monthlyRevenueUSD : 0);
    });
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
          ? "An earning estimate is unavailable for the models that fit this Mac."
          : "No currently supported model fits in " + effectiveRAM + " GB.",
      );
      setDisplay("calc-nofit", !hasFittingModel);
      if (!hasFittingModel) {
        setText(
          "calc-nofit-msg",
          "No currently supported model fits in " + effectiveRAM + " GB.",
        );
      }
      return;
    }

    const result = best.estimate;
    setText("calc-hero-primary", fmtUSD(result.monthlyRevenueUSD));
    setText(
      "calc-hero-annualized",
      fmtUSD(result.annualRevenueUSD) + "/yr at " + state.dutyCyclePercent + "% duty cycle",
    );
    setDisplay("calc-hero-unit", true);
    setDisplay("calc-nofit", false);
    setDisplay("calc-flow-section", true);
    renderFlow(result, config);
  }

  document.addEventListener("DOMContentLoaded", function () {
    const macTypeSelect = document.getElementById("mac-type-select");
    if (macTypeSelect) {
      macTypeSelect.addEventListener("change", function () {
        state.macType = macTypeSelect.value;
        state.chip = "";
        state.ram = null;
        render();
      });
    }
    const chipSelect = document.getElementById("chip-select");
    if (chipSelect) {
      chipSelect.addEventListener("change", function () {
        state.chip = chipSelect.value;
        state.ram = null;
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
    const dutyInput = document.getElementById("calc-duty-input");
    if (dutyInput) {
      dutyInput.addEventListener("input", function () {
        state.dutyCyclePercent = Number(dutyInput.value);
        render();
      });
    }

    const notifyButton = document.getElementById("calc-nofit-btn");
    if (notifyButton) {
      notifyButton.addEventListener("click", function () {
        if (window.va) {
          const selectedHardware = hardwareOption(state.macType, state.chip);
          if (!selectedHardware) return;
          window.va("event", {
            name: "small_models_interest_click",
            data: {
              source: "landing_earn_calc",
              mac_type: selectedHardware.macType,
              chip: selectedHardware.chip,
              ram_gb: state.ram,
            },
          });
        }
      });
    }
    const readinessButton = document.getElementById("calc-readiness-btn");
    if (readinessButton) {
      readinessButton.addEventListener("click", function () {
        if (window.va) {
          const selectedHardware = hardwareOption(state.macType, state.chip);
          if (!selectedHardware) return;
          window.va("event", {
            name: "production_readiness_interest_click",
            data: {
              source: "landing_earn_calc",
              mac_type: selectedHardware.macType,
              chip: selectedHardware.chip,
              ram_gb: state.ram,
            },
          });
        }
      });
    }

    if (!Core || PROVIDER_HARDWARE_OPTIONS.length === 0) {
      render();
      return;
    }
    render();
  });
})();
