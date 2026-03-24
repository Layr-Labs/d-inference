"use client";

import { useEffect, useState } from "react";
import { TopBar } from "@/components/TopBar";
import { fetchModels, type Model } from "@/lib/api";
import {
  Cpu,
  Shield,
  ShieldCheck,
  HardDrive,
  Users,
  Loader2,
} from "lucide-react";

function formatBytes(bytes: number): string {
  if (bytes >= 1e9) return `${(bytes / 1e9).toFixed(1)} GB`;
  if (bytes >= 1e6) return `${(bytes / 1e6).toFixed(0)} MB`;
  return `${bytes} B`;
}

function TrustIndicator({ level }: { level?: string }) {
  switch (level) {
    case "hardware":
      return (
        <div className="flex items-center gap-1 text-accent-green">
          <ShieldCheck size={12} />
          <span className="text-[10px] font-mono uppercase tracking-wider">
            Hardware
          </span>
        </div>
      );
    case "self_signed":
      return (
        <div className="flex items-center gap-1 text-accent-amber">
          <Shield size={12} />
          <span className="text-[10px] font-mono uppercase tracking-wider">
            Self-Signed
          </span>
        </div>
      );
    default:
      return (
        <div className="flex items-center gap-1 text-text-tertiary">
          <Shield size={12} />
          <span className="text-[10px] font-mono uppercase tracking-wider">
            None
          </span>
        </div>
      );
  }
}

export default function ModelsPage() {
  const [models, setModels] = useState<Model[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetchModels()
      .then((m) => {
        setModels(m);
        setLoading(false);
      })
      .catch(() => setLoading(false));
  }, []);

  return (
    <div className="flex flex-col h-full">
      <TopBar title="Models" />

      <div className="flex-1 overflow-y-auto">
        <div className="max-w-5xl mx-auto px-6 py-8">
          <div className="mb-6">
            <h2 className="text-lg font-semibold text-text-primary mb-1">
              Available Models
            </h2>
            <p className="text-sm text-text-tertiary">
              Models served by hardware-attested providers on the DGInf network.
            </p>
          </div>

          {loading ? (
            <div className="flex items-center justify-center py-20 text-text-tertiary">
              <Loader2 size={20} className="animate-spin mr-2" />
              Loading models...
            </div>
          ) : models.length === 0 ? (
            <div className="text-center py-20">
              <Cpu
                size={32}
                className="text-text-tertiary mx-auto mb-3 opacity-50"
              />
              <p className="text-sm text-text-tertiary">
                No models available. Check your coordinator connection in
                Settings.
              </p>
            </div>
          ) : (
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              {models.map((model) => {
                const name = model.id.split("/").pop() || model.id;
                const org = model.id.includes("/")
                  ? model.id.split("/")[0]
                  : undefined;

                return (
                  <div
                    key={model.id}
                    className="group rounded-xl border border-border-dim bg-bg-secondary p-5 hover:border-accent-purple/30 hover:bg-bg-tertiary transition-all"
                  >
                    {/* Header */}
                    <div className="flex items-start justify-between mb-3">
                      <div className="flex items-center gap-2">
                        <div className="w-8 h-8 rounded-lg bg-accent-purple/10 border border-accent-purple/20 flex items-center justify-center">
                          <Cpu size={14} className="text-accent-purple" />
                        </div>
                        <div>
                          <h3 className="text-sm font-medium text-text-primary leading-tight">
                            {name}
                          </h3>
                          {org && (
                            <p className="text-[10px] font-mono text-text-tertiary">
                              {org}
                            </p>
                          )}
                        </div>
                      </div>
                      <TrustIndicator level={model.trust_level} />
                    </div>

                    {/* Metadata pills */}
                    <div className="flex flex-wrap gap-1.5 mb-4">
                      {model.model_type && (
                        <span className="px-2 py-0.5 rounded bg-bg-elevated text-[10px] font-mono text-text-tertiary border border-border-dim">
                          {model.model_type}
                        </span>
                      )}
                      {model.quantization && (
                        <span className="px-2 py-0.5 rounded bg-accent-green-dim/30 text-[10px] font-mono text-accent-green border border-accent-green/20">
                          {model.quantization}
                        </span>
                      )}
                      {model.size_bytes && (
                        <span className="px-2 py-0.5 rounded bg-bg-elevated text-[10px] font-mono text-text-tertiary border border-border-dim">
                          {formatBytes(model.size_bytes)}
                        </span>
                      )}
                    </div>

                    {/* Footer */}
                    <div className="flex items-center justify-between pt-3 border-t border-border-dim">
                      <div className="flex items-center gap-1 text-text-tertiary">
                        <Users size={11} />
                        <span className="text-[10px] font-mono">
                          {model.provider_count ?? 0} provider
                          {(model.provider_count ?? 0) !== 1 ? "s" : ""}
                        </span>
                      </div>
                      {model.attested && (
                        <div className="flex items-center gap-1">
                          <HardDrive size={10} className="text-accent-green" />
                          <span className="text-[10px] font-mono text-accent-green">
                            Attested
                          </span>
                        </div>
                      )}
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
