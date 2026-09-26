// Pure presentation model for /app-attest/diagnostics. No DB or React imports,
// so cohort/dimension ordering and "no data yet" handling stay unit-testable.

export const COHORTS = [
  { id: "is_supported_false", label: "DCAppAttestService.isSupported == false", detail: "Ready reply unsupported with availability_reason is_supported_false." },
  { id: "fresh_key_invalid_key", label: "Fresh-key enrollment apple_invalid_key", detail: "First attestKey for a newly generated key returned DeviceCheck invalidKey." },
  { id: "dead_key_assertion", label: "Assertion apple_error code 0 (dead key)", detail: "Assertion failed with DeviceCheck code 0 or no coded error (proof_oversize excluded)." },
  { id: "stalled_busy", label: "Stalled busy", detail: "Client reported an Apple operation still in flight (busy)." },
  { id: "identity_required", label: "identity_required", detail: "Rollout skipped: no authenticated account for this connection." },
] as const;
export type Cohort = (typeof COHORTS)[number]["id"];

// Order is display order. Values come from coordinator-validated closed enums,
// booleans or bounded labels; the query maps each name to one JSON expression.
export const DIMENSIONS = [
  "launch_session", "console_user_active", "sip_enabled", "authenticated_root",
  "preflight.opt_in_entitlement", "preflight.environment_entitlement", "preflight.profile_present",
  "preflight.profile_expired", "preflight.bundle_path_class",
  "previous_exit", "start_reason", "rebooted_since_last_success", "process_restarted_since_last_success",
  "key_history.created_boot_matches", "key_history.generations_last_24h", "os_build", "provider_version", "chip_family",
  "operation_stalled_seconds", "native_error_entry", "native_error_chain",
] as const;
export type Dimension = (typeof DIMENSIONS)[number];

export interface BreakdownRow {
  cohort: string;
  dimension: string;
  /** null = the event carried no value for this dimension (old client/row). */
  value: string | null;
  machines: string;
  events: string;
}

export interface DimensionBreakdown {
  dimension: Dimension;
  /** True when no event in the cohort reported this dimension. */
  noData: boolean;
  values: { value: string; machines: number; events: number }[];
  /** Events in the cohort that did not report this dimension. */
  missingEvents: number;
}

/** Groups flat breakdown rows into every cohort × dimension, in display order. */
export function groupBreakdown(rows: BreakdownRow[]): Record<Cohort, DimensionBreakdown[]> {
  const byKey = new Map<string, BreakdownRow[]>();
  for (const row of rows) {
    const key = `${row.cohort}\u0000${row.dimension}`;
    const list = byKey.get(key);
    if (list) list.push(row);
    else byKey.set(key, [row]);
  }
  const result = {} as Record<Cohort, DimensionBreakdown[]>;
  for (const { id } of COHORTS) {
    result[id] = DIMENSIONS.map((dimension) => {
      const list = byKey.get(`${id}\u0000${dimension}`) ?? [];
      const values = list.filter((r) => r.value !== null)
        .map((r) => ({ value: r.value as string, machines: Number(r.machines), events: Number(r.events) }));
      const missingEvents = list.filter((r) => r.value === null).reduce((n, r) => n + Number(r.events), 0);
      return { dimension, noData: values.length === 0, values, missingEvents };
    });
  }
  return result;
}

export const DEATH_CLASSES = ["os_change", "reboot", "process_restart", "no_restart", "unknown"] as const;
export type DeathClass = (typeof DEATH_CLASSES)[number];

export interface DeathDayRow {
  day: string;
  classification: string;
  keys: string;
  machines: string;
  clean_exit: string;
  unclean_exit: string;
  /** Distinct machines over the whole day, across classifications. */
  day_machines: string;
}

/** Pivots per-day key-death rows into one row per day (newest first) with a
 * count per classification; unknown classifications fold into "unknown". */
export function pivotDeaths(rows: DeathDayRow[]) {
  const days = new Map<string, Record<DeathClass, number> & { clean: number; unclean: number; machines: number }>();
  for (const row of rows) {
    let day = days.get(row.day);
    if (!day) {
      day = { os_change: 0, reboot: 0, process_restart: 0, no_restart: 0, unknown: 0, clean: 0, unclean: 0, machines: 0 };
      days.set(row.day, day);
    }
    const cls = (DEATH_CLASSES as readonly string[]).includes(row.classification) ? row.classification as DeathClass : "unknown";
    day[cls] += Number(row.keys);
    day.clean += Number(row.clean_exit);
    day.unclean += Number(row.unclean_exit);
    day.machines = Number(row.day_machines);
  }
  return [...days.entries()].sort(([a], [b]) => b.localeCompare(a)).map(([day, counts]) => ({ day, ...counts }));
}
