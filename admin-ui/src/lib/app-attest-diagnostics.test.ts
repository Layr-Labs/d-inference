import { describe, expect, it } from "vitest";
import { groupBreakdown, pivotDeaths } from "./app-attest-diagnostics";

describe("groupBreakdown", () => {
  it("marks dimensions without reported values as no data and keeps missing-event counts", () => {
    const grouped = groupBreakdown([
      { cohort: "dead_key_assertion", dimension: "previous_exit", value: "unclean", machines: "3", events: "7" },
      { cohort: "dead_key_assertion", dimension: "previous_exit", value: null, machines: "2", events: "4" },
      { cohort: "dead_key_assertion", dimension: "sip_enabled", value: null, machines: "5", events: "11" },
    ]);
    const dims = grouped.dead_key_assertion;
    const exit = dims.find(d => d.dimension === "previous_exit");
    expect(exit).toEqual({ dimension: "previous_exit", noData: false, values: [{ value: "unclean", machines: 3, events: 7 }], missingEvents: 4 });
    expect(dims.find(d => d.dimension === "sip_enabled")).toMatchObject({ noData: true, values: [], missingEvents: 11 });
    // Cohorts with no rows still render every dimension as no data.
    expect(grouped.is_supported_false.every(d => d.noData && d.missingEvents === 0)).toBe(true);
  });

  it("ignores cohorts and dimensions the page does not know", () => {
    const grouped = groupBreakdown([{ cohort: "future", dimension: "previous_exit", value: "clean", machines: "1", events: "1" }]);
    expect(Object.keys(grouped)).not.toContain("future");
  });
});

describe("pivotDeaths", () => {
  it("pivots per-day classifications newest first and folds unknown classes", () => {
    const days = pivotDeaths([
      { day: "2026-09-24", classification: "reboot", keys: "2", machines: "2", clean_exit: "1", unclean_exit: "0", day_machines: "2" },
      { day: "2026-09-25", classification: "process_restart", keys: "5", machines: "4", clean_exit: "0", unclean_exit: "5", day_machines: "4" },
      { day: "2026-09-25", classification: "something_new", keys: "1", machines: "1", clean_exit: "0", unclean_exit: "0", day_machines: "4" },
    ]);
    expect(days.map(d => d.day)).toEqual(["2026-09-25", "2026-09-24"]);
    expect(days[0]).toMatchObject({ process_restart: 5, unknown: 1, reboot: 0, unclean: 5 });
    expect(days[1]).toMatchObject({ reboot: 2, clean: 1 });
  });

  it("uses the day's distinct machine count instead of summing per-class counts", () => {
    // One Mac lost keys to a reboot and to a process restart on the same day.
    const [day] = pivotDeaths([
      { day: "2026-09-25", classification: "reboot", keys: "1", machines: "1", clean_exit: "0", unclean_exit: "0", day_machines: "1" },
      { day: "2026-09-25", classification: "process_restart", keys: "1", machines: "1", clean_exit: "0", unclean_exit: "1", day_machines: "1" },
    ]);
    expect(day).toMatchObject({ reboot: 1, process_restart: 1, machines: 1 });
  });
});
