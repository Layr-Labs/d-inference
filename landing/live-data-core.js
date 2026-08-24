(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  } else {
    root.DarkbloomLiveData = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const REQUEST_TIMEOUT_MS = 10_000;

  function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
  }

  function isNonNegativeInteger(value) {
    return typeof value === "number" &&
      Number.isFinite(value) &&
      Number.isSafeInteger(value) &&
      value >= 0;
  }

  function fetchJSONWithTimeout(fetchFunction, url, timeoutMS) {
    if (typeof fetchFunction !== "function") {
      return Promise.reject(new Error("Fetch unavailable"));
    }
    const deadlineMS =
      Number.isFinite(timeoutMS) && timeoutMS > 0 ? timeoutMS : REQUEST_TIMEOUT_MS;
    const controller =
      typeof AbortController === "function" ? new AbortController() : null;
    let timer;
    const request = Promise.resolve()
      .then(function () {
        const options = { headers: { Accept: "application/json" } };
        if (controller) options.signal = controller.signal;
        return fetchFunction(url, options);
      })
      .then(function (response) {
        if (!response || !response.ok) {
          throw new Error("Request failed" + (response ? ": " + response.status : ""));
        }
        return response.json();
      });
    const deadline = new Promise(function (_resolve, reject) {
      timer = setTimeout(function () {
        if (controller) controller.abort();
        reject(new Error("Request timed out"));
      }, deadlineMS);
    });
    return Promise.race([request, deadline]).finally(function () {
      clearTimeout(timer);
    });
  }

  function resolveModelPricing(models, pricing) {
    if (
      !Array.isArray(models) ||
      models.length === 0 ||
      !isObject(pricing) ||
      !Array.isArray(pricing.prices)
    ) {
      return null;
    }
    const fallbackInput = isNonNegativeInteger(pricing.fallback_input_price)
      ? pricing.fallback_input_price
      : null;
    const fallbackOutput = isNonNegativeInteger(pricing.fallback_output_price)
      ? pricing.fallback_output_price
      : null;
    const priceByModel = new Map();
    for (const price of pricing.prices) {
      if (
        !isObject(price) ||
        typeof price.model !== "string" ||
        price.model.length === 0 ||
        priceByModel.has(price.model)
      ) {
        return null;
      }
      priceByModel.set(price.model, price);
    }
    const resolved = [];
    for (const model of models) {
      if (!isObject(model) || typeof model.id !== "string" || model.id.length === 0) {
        return null;
      }
      const price = priceByModel.get(model.id);
      const inputPrice =
        price && isNonNegativeInteger(price.input_price)
          ? price.input_price
          : fallbackInput;
      const outputPrice =
        price && isNonNegativeInteger(price.output_price)
          ? price.output_price
          : fallbackOutput;
      if (inputPrice === null || outputPrice === null) {
        return null;
      }
      resolved.push({
        model: model,
        inputPrice: inputPrice,
        outputPrice: outputPrice,
      });
    }
    return resolved;
  }

  return {
    REQUEST_TIMEOUT_MS: REQUEST_TIMEOUT_MS,
    fetchJSONWithTimeout: fetchJSONWithTimeout,
    resolveModelPricing: resolveModelPricing,
  };
});
