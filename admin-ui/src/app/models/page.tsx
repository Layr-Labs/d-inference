import {
  listModels,
  countModels,
  type ModelRow,
  DEFAULT_INPUT_PRICE_MICRO,
  DEFAULT_OUTPUT_PRICE_MICRO,
} from "@/lib/queries/models";
import { DataTable, type Column } from "@/components/DataTable";
import { formatNumber, formatUSDFromMicro } from "@/lib/format";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// total_size_bytes is a BIGINT (string from pg) → human GB.
function formatGB(bytes: string | null): string {
  if (bytes === null || bytes === "") return "—";
  const v = Number(bytes);
  if (Number.isNaN(v)) return "—";
  return `${(v / 1e9).toFixed(1)} GB`;
}

// Platform price per 1M tokens. When unset, the coordinator charges the default
// fallback — show that value tagged "(default)" so it's clear it's not an override.
function PriceCell({ micro, fallback }: { micro: string | null; fallback: number }) {
  if (micro != null && micro !== "") return <>{formatUSDFromMicro(micro)}</>;
  return (
    <span className="text-[var(--text-faint)]">
      {formatUSDFromMicro(fallback)} (default)
    </span>
  );
}

const COLUMNS: Column<ModelRow>[] = [
  { key: "display_name", header: "Name", render: (m) => m.display_name || "—" },
  { key: "id", header: "ID", mono: true },
  { key: "family", header: "Family", render: (m) => m.family || "—" },
  { key: "architecture", header: "Arch", render: (m) => m.architecture || "—" },
  { key: "quantization", header: "Quant", render: (m) => m.quantization || "—" },
  { key: "status", header: "Status", render: (m) => m.status || "—" },
  {
    key: "min_ram_gb",
    header: "Min RAM",
    align: "right",
    render: (m) => (m.min_ram_gb == null || m.min_ram_gb === 0 ? "—" : `${m.min_ram_gb} GB`),
  },
  {
    key: "max_context_length",
    header: "Context",
    align: "right",
    render: (m) =>
      m.max_context_length == null || m.max_context_length === 0
        ? "—"
        : formatNumber(m.max_context_length),
  },
  {
    key: "capabilities",
    header: "Capabilities",
    render: (m) => (m.capabilities.length ? m.capabilities.join(", ") : "—"),
  },
  {
    key: "active_version",
    header: "Active ver.",
    mono: true,
    render: (m) =>
      m.active_version || <span className="text-[var(--text-faint)]">none</span>,
  },
  {
    key: "total_size_bytes",
    header: "Size",
    align: "right",
    render: (m) => formatGB(m.total_size_bytes),
  },
  {
    key: "input_price_micro",
    header: "Input $/1M",
    align: "right",
    render: (m) => <PriceCell micro={m.input_price_micro} fallback={DEFAULT_INPUT_PRICE_MICRO} />,
  },
  {
    key: "output_price_micro",
    header: "Output $/1M",
    align: "right",
    render: (m) => <PriceCell micro={m.output_price_micro} fallback={DEFAULT_OUTPUT_PRICE_MICRO} />,
  },
];

export default async function ModelsPage() {
  const [rows, total] = await Promise.all([listModels(200), countModels()]);
  return (
    <div className="space-y-4">
      <h1 className="text-lg font-semibold">
        Models <span className="text-[var(--text-faint)]">({formatNumber(total)})</span>
      </h1>
      <p className="text-sm text-[var(--text-dim)]">
        All registered models, ordered by name. Active version and size come from the
        currently-promoted version (if any). Prices are the platform rate per 1M tokens;
        models without an explicit price use the coordinator default.
      </p>
      <DataTable columns={COLUMNS} rows={rows} empty="No models." />
    </div>
  );
}
