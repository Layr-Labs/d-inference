import { DataTable, type Column } from "@/components/DataTable";
import {
  MachineSignal,
  SupplyLossMeter,
  TTFTValue,
} from "@/components/supply/SupplyPressureCells";
import { StatCard } from "@/components/StatCard";
import { isUndefinedTable } from "@/lib/db";
import { formatNumber, formatPercent } from "@/lib/format";
import { getSupplyPressure } from "@/lib/queries/supply";
import type { SupplyPressureModel } from "@/lib/supply-pressure";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function ModelCell({ model }: { model: SupplyPressureModel }) {
  return (
    <div className="min-w-56">
      <div className="font-medium">{model.displayName}</div>
      {model.displayName !== model.model && (
        <div className="mono mt-0.5 text-[var(--text-faint)]">{model.model}</div>
      )}
      {model.minRamGB !== null && model.minRamGB > 0 && (
        <div className="mt-1 text-xs text-[var(--text-faint)]">
          catalog minimum {formatNumber(model.minRamGB)} GB RAM
        </div>
      )}
    </div>
  );
}

function PressureCount({ value }: { value: number }) {
  return value > 0 ? (
    <span style={{ color: "var(--red)" }}>{formatNumber(value)}</span>
  ) : (
    <span className="text-[var(--text-faint)]">0</span>
  );
}

const COLUMNS: Column<SupplyPressureModel>[] = [
  { key: "model", header: "Model", render: (model) => <ModelCell model={model} /> },
  {
    key: "signal",
    header: "Machine signal",
    render: (model) => <MachineSignal model={model} />,
  },
  {
    key: "unserved1h",
    header: "Unserved 1h",
    align: "right",
    render: (model) => <PressureCount value={model.unserved1h} />,
  },
  {
    key: "unserved24h",
    header: "Unserved 24h",
    align: "right",
    render: (model) => <PressureCount value={model.unserved24h} />,
  },
  {
    key: "served24h",
    header: "Served 24h",
    align: "right",
    render: (model) => formatNumber(model.served24h),
  },
  {
    key: "lossRate",
    header: "Supply loss",
    align: "right",
    render: (model) => (
      <SupplyLossMeter unserved={model.unserved24h} served={model.served24h} />
    ),
  },
  {
    key: "capacitySheds24h",
    header: "Busy / queue",
    align: "right",
    render: (model) => <PressureCount value={model.capacitySheds24h} />,
  },
  {
    key: "latencySheds24h",
    header: "TTFT / deadline",
    align: "right",
    render: (model) => <PressureCount value={model.latencySheds24h} />,
  },
  {
    key: "unavailableSheds24h",
    header: "No provider",
    align: "right",
    render: (model) => <PressureCount value={model.unavailableSheds24h} />,
  },
  {
    key: "actualTTFT",
    header: "Observed p95 TTFT",
    align: "right",
    render: (model) => (
      <TTFTValue
        current={model.actualTTFTP95Ms1h}
        fallback={model.actualTTFTP95Ms24h}
      />
    ),
  },
  {
    key: "rejectedTTFT",
    header: "Rejected best p95",
    align: "right",
    render: (model) => (
      <TTFTValue
        current={model.rejectedTTFTP95Ms1h}
        fallback={model.rejectedTTFTP95Ms24h}
      />
    ),
  },
  {
    key: "hardwareMismatches24h",
    header: "Needs larger RAM",
    align: "right",
    render: (model) => <PressureCount value={model.hardwareMismatches24h} />,
  },
];

function NotDeployed() {
  return (
    <div className="space-y-4">
      <h1 className="text-lg font-semibold">Supply pressure</h1>
      <div className="rounded-lg border border-[var(--border)] bg-[var(--bg-elevated)] p-4 text-sm text-[var(--text-dim)]">
        <div className="font-medium text-[var(--text)]">Supply telemetry not deployed yet</div>
        <p className="mt-1">
          The routing and rejection tables do not exist on the replica yet. This view will
          populate after a coordinator with supply telemetry is deployed.
        </p>
      </div>
    </div>
  );
}

export default async function SupplyPage() {
  let data;
  try {
    data = await getSupplyPressure();
  } catch (error) {
    if (isUndefinedTable(error)) return <NotDeployed />;
    throw error;
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-lg font-semibold">Supply pressure</h1>
        <p className="mt-1 text-sm text-[var(--text-dim)]">
          Public-network demand lost to saturation, unavailable providers, or TTFT
          deadlines. Exclusive self-route traffic and non-supply rejections are excluded.
        </p>
      </div>

      <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
        <StatCard label="Unserved (1h)" value={formatNumber(data.summary.unserved1h)} />
        <StatCard label="Unserved (24h)" value={formatNumber(data.summary.unserved24h)} />
        <StatCard
          label="Supply loss (24h)"
          value={formatPercent(data.summary.supplyLossRate24h)}
        />
        <StatCard
          label="Models pressured now"
          value={formatNumber(data.summary.pressuredModels1h)}
        />
      </div>

      <div className="rounded-lg border border-[var(--border)] bg-[var(--bg-elevated)] p-4 text-sm text-[var(--text-dim)]">
        <span className="font-medium text-[var(--text)]">How to read this:</span>{" "}
        <span className="text-[var(--red)]">Add machines</span> means capacity or queue
        sheds dominate. <span className="text-[var(--amber)]">Warm / faster</span> means
        TTFT or deadline sheds dominate. Model-too-large requests are reported separately
        because adding more machines of the same size cannot serve them. P95 values use
        the last hour when available, otherwise the last 24 hours.
      </div>

      <DataTable
        columns={COLUMNS}
        rows={data.models}
        empty="No served traffic or supply-pressure signals in the last 24 hours."
      />
    </div>
  );
}
