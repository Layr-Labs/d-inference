import assert from "node:assert/strict";
import test from "node:test";
import { parsePricing } from "./pricing.ts";

test("matches model IDs and converts micro-USD without inventing prices", () => {
  assert.deepEqual(
    parsePricing(
      {
        models: [
          { id: "one", display_name: "One", max_context_length: 131072 },
          { id: "unpriced" },
        ],
      },
      {
        prices: [{ model: "one", input_price: 30000, output_price: 165000 }],
      },
    ),
    [{ id: "one", name: "One", input: 0.03, output: 0.165, context: 131072 }],
  );
});

test("rejects malformed responses and invalid prices so callers retain fallback rows", () => {
  for (const response of [null, [], {}, { models: null }])
    assert.deepEqual(parsePricing(response, response), []);
  for (const price of [-1, "30000", null, Infinity, NaN]) {
    assert.deepEqual(
      parsePricing(
        { models: [{ id: "one" }] },
        { prices: [{ model: "one", input_price: price, output_price: 100 }] },
      ),
      [],
    );
  }
});

test("uses explicit API fallback rates, including zero, when a model has no price", () => {
  assert.deepEqual(
    parsePricing(
      { models: [{ id: "free" }] },
      { prices: [], fallback_input_price: 0, fallback_output_price: 0 },
    ),
    [{ id: "free", name: "free", input: 0, output: 0, context: undefined }],
  );
});
