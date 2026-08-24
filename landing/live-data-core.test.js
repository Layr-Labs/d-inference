"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const LiveData = require("./live-data-core.js");

test("stalled public-data requests terminate at the configured deadline", async function () {
  let signal;
  await assert.rejects(
    LiveData.fetchJSONWithTimeout(function (_url, options) {
      signal = options.signal;
      return new Promise(function () {});
    }, "https://example.test/market", 5),
    /Request timed out/,
  );
  assert.equal(signal.aborted, true);
});

test("successful public-data requests return parsed JSON", async function () {
  const payload = { models: [{ id: "model-a" }] };
  const result = await LiveData.fetchJSONWithTimeout(function (_url, options) {
    assert.equal(options.headers.Accept, "application/json");
    return Promise.resolve({
      ok: true,
      json: function () {
        return Promise.resolve(payload);
      },
    });
  }, "https://example.test/catalog", 100);
  assert.equal(result, payload);
});

test("pricing requires explicit model prices or valid fallbacks", function () {
  const models = [{ id: "model-a" }, { id: "model-b" }];
  assert.deepEqual(
    LiveData.resolveModelPricing(models, {
      prices: [{ model: "model-a", input_price: 10, output_price: 20 }],
      fallback_input_price: 30,
      fallback_output_price: 40,
    }),
    [
      { model: models[0], inputPrice: 10, outputPrice: 20 },
      { model: models[1], inputPrice: 30, outputPrice: 40 },
    ],
  );
  assert.equal(LiveData.resolveModelPricing(models, { prices: [] }), null);
  assert.equal(
    LiveData.resolveModelPricing(models, {
      prices: [{ model: "model-a", input_price: 10 }],
      fallback_input_price: 30,
    }),
    null,
  );
});
