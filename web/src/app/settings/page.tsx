"use client";

import { useState, useEffect } from "react";
import { TopBar } from "@/components/TopBar";
import { useToastStore } from "@/hooks/useToast";
import {
  Key,
  Globe,
  Eye,
  EyeOff,
  Check,
  AlertCircle,
  Loader2,
  Server,
  Plus,
} from "lucide-react";
import { healthCheck } from "@/lib/api";

export default function SettingsPage() {
  const addToast = useToastStore((s) => s.addToast);
  const [apiKey, setApiKey] = useState("");
  const [coordinatorUrl, setCoordinatorUrl] = useState("");
  const [showKey, setShowKey] = useState(false);
  const [saved, setSaved] = useState(false);
  const [generating, setGenerating] = useState(false);
  const [healthStatus, setHealthStatus] = useState<
    "idle" | "checking" | "ok" | "error"
  >("idle");
  const [healthInfo, setHealthInfo] = useState("");

  useEffect(() => {
    if (typeof window !== "undefined") {
      setApiKey(localStorage.getItem("dginf_api_key") || "");
      setCoordinatorUrl(
        localStorage.getItem("dginf_coordinator_url") ||
          process.env.NEXT_PUBLIC_COORDINATOR_URL ||
          "http://localhost:8080"
      );
    }
  }, []);

  const handleSave = () => {
    localStorage.setItem("dginf_api_key", apiKey);
    localStorage.setItem("dginf_coordinator_url", coordinatorUrl);
    setSaved(true);
    addToast("Settings saved", "success");
    setTimeout(() => setSaved(false), 2000);
  };

  const handleGenerateKey = async () => {
    setGenerating(true);
    try {
      // Save coordinator URL first so the proxy knows where to go
      localStorage.setItem("dginf_coordinator_url", coordinatorUrl);

      const res = await fetch("/api/auth/keys", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-coordinator-url": coordinatorUrl,
        },
      });

      if (!res.ok) {
        throw new Error(`Failed to generate key: ${res.status}`);
      }

      const data = await res.json();
      const newKey = data.api_key;
      setApiKey(newKey);
      localStorage.setItem("dginf_api_key", newKey);
      setShowKey(true);
      addToast("API key generated and saved", "success");
    } catch (err) {
      addToast(`Key generation failed: ${(err as Error).message}`);
    }
    setGenerating(false);
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

  const maskedKey = apiKey
    ? apiKey.slice(0, 8) + "•".repeat(Math.max(0, apiKey.length - 12)) + apiKey.slice(-4)
    : "";

  return (
    <div className="flex flex-col h-full">
      <TopBar title="Settings" />

      <div className="flex-1 overflow-y-auto">
        <div className="max-w-2xl mx-auto px-6 py-8 space-y-8">
          {/* Coordinator URL — first, since key generation needs it */}
          <section className="rounded-xl border border-border-dim bg-bg-secondary p-6">
            <div className="flex items-center gap-2 mb-4">
              <Globe size={14} className="text-accent-green" />
              <h3 className="text-sm font-medium text-text-primary">
                Coordinator URL
              </h3>
            </div>
            <p className="text-xs text-text-tertiary mb-4">
              The base URL of the DGInf coordinator that routes your inference
              requests to attested providers.
            </p>
            <input
              type="text"
              value={coordinatorUrl}
              onChange={(e) => setCoordinatorUrl(e.target.value)}
              placeholder="https://coordinator.dginf.io"
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

          {/* API Key */}
          <section className="rounded-xl border border-border-dim bg-bg-secondary p-6">
            <div className="flex items-center gap-2 mb-4">
              <Key size={14} className="text-accent-purple" />
              <h3 className="text-sm font-medium text-text-primary">
                API Key
              </h3>
            </div>
            <p className="text-xs text-text-tertiary mb-4">
              Your DGInf API key for authenticating with the coordinator. Generate
              a new one or paste an existing key.
            </p>
            <div className="relative">
              <input
                type={showKey ? "text" : "password"}
                value={apiKey}
                onChange={(e) => setApiKey(e.target.value)}
                placeholder="dginf-..."
                className="w-full bg-bg-tertiary border border-border-subtle rounded-lg px-4 py-3 pr-12 text-text-primary font-mono text-sm outline-none focus:border-accent-purple/50 transition-colors"
              />
              <button
                onClick={() => setShowKey(!showKey)}
                className="absolute right-3 top-1/2 -translate-y-1/2 p-1 text-text-tertiary hover:text-text-secondary transition-colors"
              >
                {showKey ? <EyeOff size={14} /> : <Eye size={14} />}
              </button>
            </div>
            {apiKey && !showKey && (
              <p className="mt-2 text-xs font-mono text-text-tertiary">
                {maskedKey}
              </p>
            )}

            {/* Generate key button */}
            <button
              onClick={handleGenerateKey}
              disabled={generating}
              className="mt-4 flex items-center gap-2 px-3 py-1.5 rounded-lg bg-accent-purple/10 border border-accent-purple/25 text-accent-purple text-xs font-mono hover:bg-accent-purple/20 transition-colors disabled:opacity-50"
            >
              {generating ? (
                <Loader2 size={12} className="animate-spin" />
              ) : (
                <Plus size={12} />
              )}
              Generate New Key
            </button>
          </section>

          {/* Save */}
          <button
            onClick={handleSave}
            className="w-full py-3 rounded-lg bg-accent-purple text-white font-medium text-sm hover:bg-accent-purple/90 transition-colors flex items-center justify-center gap-2"
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
          <div className="rounded-xl border border-border-dim bg-bg-secondary p-5">
            <h4 className="text-xs font-mono text-text-tertiary uppercase tracking-wider mb-3">
              About DGInf
            </h4>
            <div className="space-y-2 text-xs text-text-tertiary leading-relaxed">
              <p>
                DGInf is a decentralized private inference network. Your
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
