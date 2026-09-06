import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { expect, it } from "vitest";
import type { PagedStorageTelemetry } from "@/app/providers/types";

it("preserves allocator padding separately from usable slack in the canonical wire", () => {
  const sample = JSON.parse(readFileSync(resolve(process.cwd(),
    "../coordinator/protocol/testdata/paged_footprint_wire.json"), "utf8")) as PagedStorageTelemetry;
  expect(sample.committed_bytes).toBe(sample.reserved_page_bytes + sample.poison_bytes
    + sample.slack_bytes + sample.allocator_padding_bytes!);
  expect(sample.last_allocation_allowance_bytes).toBe(77);
  delete sample.allocator_padding_bytes;
  delete sample.last_allocation_allowance_bytes;
  const legacy = JSON.parse(JSON.stringify(sample)) as PagedStorageTelemetry;
  expect(legacy.allocator_padding_bytes).toBeUndefined();
  expect(legacy.last_allocation_allowance_bytes).toBeUndefined();
});
