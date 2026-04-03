"use client";

import { useState, useEffect } from "react";
import { TopBar } from "@/components/TopBar";
import { useToastStore } from "@/hooks/useToast";
import {
  Globe,
  Check,
  AlertCircle,
  Loader2,
  Server,
} from "lucide-react";
import { healthCheck } from "@/lib/api";

export default function SettingsPage() {
  const addToast = useToastStore((s) => s.addToast);
  const [coordinatorUrl, setCoordinatorUrl] = useState("");
  const [saved, setSaved] = useState(false);
  const [healthStatus, setHealthStatus] = useState<
    "idle" | "checking" | "ok" | "error"
  >("idle");
  const [healthInfo, setHealthInfo] = useState("");

  useEffect(() => {
    if (typeof window !== "undefined") {
      setCoordinatorUrl(
        localStorage.getItem("eigeninference_coordinator_url") ||
          process.env.NEXT_PUBLIC_COORDINATOR_URL ||
          "https://inference-test.openinnovation.dev"
      );
    }
  }, []);

  const handleSave = () => {
    localStorage.setItem("eigeninference_coordinator_url", coordinatorUrl);
    setSaved(true);
    addToast("Settings saved", "success");
    setTimeout(() => setSaved(false), 2000);
  };

  const handleHealthCheck = async () => {
    setHealthStatus("checking");
    try {
      const result = await healthCheck();
      setHealthStatus("ok");
      setHealthInfo(
        `Connected — ${result.providers ?? 0} provider${
          (result.providers ?? 0) !== 1 ? "s" : ""
        } online`
      );
    } catch (err) {
      setHealthStatus("error");
      setHealthInfo((err as Error).message);
    }
  };

  return (
    <div className="flex flex-col h-full">
      <TopBar title="Settings" />

      <div className="flex-1 overflow-y-auto">
        <div className="max-w-2xl mx-auto px-6 py-8 space-y-8">
          {/* Coordinator URL */}
          <section className="rounded-xl bg-bg-secondary p-6 shadow-sm">
            <div className="flex items-center gap-2 mb-4">
              <Globe size={14} className="text-accent-green" />
              <h3 className="text-sm font-medium text-text-primary">
                Coordinator URL
              </h3>
            </div>
            <p className="text-xs text-text-tertiary mb-4">
              The base URL of the EigenInference coordinator that routes your inference
              requests to attested providers.
            </p>
            <input
              type="text"
              value={coordinatorUrl}
              onChange={(e) => setCoordinatorUrl(e.target.value)}
              placeholder="https://coordinator.eigeninference.io"
              className="w-full bg-bg-tertiary border border-border-subtle rounded-lg px-4 py-3 text-text-primary font-mono text-sm outline-none focus:border-accent-green/50 transition-colors"
            />

            {/* Health check */}
            <div className="flex items-center gap-3 mt-4">
              <button
                onClick={handleHealthCheck}
                disabled={healthStatus === "checking"}
                className="flex items-center gap-2 px-3 py-1.5 rounded-lg bg-bg-tertiary border border-border-subtle text-text-secondary text-xs font-mono hover:bg-bg-hover transition-colors disabled:opacity-50"
              >
                {healthStatus === "checking" ? (
                  <Loader2 size={12} className="animate-spin" />
                ) : (
                  <Server size={12} />
                )}
                Test Connection
              </button>
              {healthStatus === "ok" && (
                <span className="flex items-center gap-1 text-xs text-accent-green font-mono">
                  <Check size={12} />
                  {healthInfo}
                </span>
              )}
              {healthStatus === "error" && (
                <span className="flex items-center gap-1 text-xs text-accent-red font-mono">
                  <AlertCircle size={12} />
                  {healthInfo}
                </span>
              )}
            </div>
          </section>

          {/* Save */}
          <button
            onClick={handleSave}
            className="w-full py-3 rounded-lg bg-accent-brand text-white font-medium text-sm hover:bg-accent-brand/90 transition-colors flex items-center justify-center gap-2"
          >
            {saved ? (
              <>
                <Check size={14} />
                Saved
              </>
            ) : (
              "Save Settings"
            )}
          </button>

          {/* Info */}
          <div className="rounded-xl bg-bg-secondary p-5 shadow-sm">
            <h4 className="text-xs font-mono text-text-tertiary uppercase tracking-wider mb-3">
              About EigenInference
            </h4>
            <div className="space-y-2 text-xs text-text-tertiary leading-relaxed">
              <p>
                EigenInference is a decentralized private inference network. Your
                requests are routed to hardware-attested Apple Silicon providers
                with Secure Enclave verification, SIP enforcement, and Hardened
                Runtime protection.
              </p>
              <p>
                Provider trust is independently verified through MDM
                (Mobile Device Management) cross-checking with the coordinator.
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
