import type { MyProvider } from "../types";

export interface ModelActivity { model: string; running: number; waiting: number; machines: string[] }

// Capacity is a point-in-time gauge, not a completion stream. Ignore stale and
// offline snapshots even when their last reported running count is nonzero.
export function modelActivity(providers: MyProvider[], now: number, heartbeatSeconds: number) {
  const models = new Map<string, ModelActivity>();
  let unknown = 0;
  for (const provider of providers) {
    if (!provider.online) continue;
    const sampled = Date.parse(provider.capacity_accepted_at ?? "");
    if (!Number.isFinite(sampled) || now - sampled > heartbeatSeconds * 1000 || !provider.backend_capacity) { unknown++; continue; }
    for (const slot of provider.backend_capacity.slots) {
      if (slot.state !== "running" && slot.state !== "idle") continue;
      const row = models.get(slot.model) ?? { model: slot.model, running: 0, waiting: 0, machines: [] };
      row.running += Math.max(0, slot.num_running);
      row.waiting += Math.max(0, slot.num_waiting);
      if (!row.machines.includes(provider.id)) row.machines.push(provider.id);
      models.set(slot.model, row);
    }
  }
  return { models: [...models.values()].sort((a, b) => b.running - a.running || a.model.localeCompare(b.model)), unknown };
}

export const TOKEN_MILESTONES = [100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000, 10_000_000_000, 100_000_000_000, 1_000_000_000_000];
export function tokenProgress(tokens: number) {
  const achieved = TOKEN_MILESTONES.filter(target => tokens >= target);
  const next = TOKEN_MILESTONES.find(target => tokens < target) ?? null;
  const previous = achieved.at(-1) ?? 0;
  return { achieved, next, previous, progress: next === null ? 100 : Math.max(0, Math.min(100, (tokens - previous) / (next - previous) * 100)) };
}
