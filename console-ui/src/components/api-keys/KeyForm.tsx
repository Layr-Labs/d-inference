"use client";

import { useState } from "react";
import { Check, Loader2 } from "lucide-react";
import type { ApiKey, KeyResetWindow, UpdateKeyBody } from "@/lib/api";
import { INPUT_CLS, LABEL_CLS, RESET_OPTIONS } from "./constants";
import { plural } from "./format";
import { expiryOrClear, intOrClear, modelsOrClear, numOrClear } from "./limits";

// KeyForm is the create/edit form. On "create" an empty field omits the limit;
// on "edit" an empty field clears it (see the limits.ts parsers).
export function KeyForm({
  initial,
  models,
  mode,
  submitting,
  onCancel,
  onSubmit,
}: {
  initial?: ApiKey;
  models: string[];
  mode: "create" | "edit";
  submitting: boolean;
  onCancel: () => void;
  onSubmit: (body: UpdateKeyBody) => void;
}) {
  const [name, setName] = useState(initial?.name ?? "");
  const [limitUsd, setLimitUsd] = useState(initial?.limit_usd != null ? String(initial.limit_usd) : "");
  const [limitReset, setLimitReset] = useState<KeyResetWindow>(initial?.limit_reset ?? "none");
  const [rpm, setRpm] = useState(initial?.rpm_limit != null ? String(initial.rpm_limit) : "");
  const [itpm, setItpm] = useState(initial?.itpm_limit != null ? String(initial.itpm_limit) : "");
  const [otpm, setOtpm] = useState(initial?.otpm_limit != null ? String(initial.otpm_limit) : "");
  const [expiresAt, setExpiresAt] = useState(initial?.expires_at ? initial.expires_at.slice(0, 10) : "");
  const [allowed, setAllowed] = useState<string[]>(initial?.allowed_models ?? []);
  const [modelQuery, setModelQuery] = useState("");
  const [modelText, setModelText] = useState((initial?.allowed_models ?? []).join(", "));
  const [selfRouteOnly, setSelfRouteOnly] = useState(initial?.self_route_only ?? false);

  const hasModels = models.length > 0;
  const nameTrim = name.trim();
  const canSubmit = !!nameTrim && !submitting;

  const toggleModel = (id: string) => {
    setAllowed((prev) => (prev.includes(id) ? prev.filter((m) => m !== id) : [...prev, id]));
  };

  const filteredModels = modelQuery.trim()
    ? models.filter((m) => m.toLowerCase().includes(modelQuery.trim().toLowerCase()))
    : models;

  const handleSubmit = () => {
    if (!canSubmit) return;
    const clear = mode === "edit";
    const selectedModels = hasModels
      ? allowed
      : modelText.split(",").map((s) => s.trim()).filter(Boolean);

    const body: UpdateKeyBody = {
      name: nameTrim,
      limit_usd: numOrClear(limitUsd, clear),
      limit_reset: limitReset,
      rpm_limit: intOrClear(rpm, clear),
      itpm_limit: intOrClear(itpm, clear),
      otpm_limit: intOrClear(otpm, clear),
      expires_at: expiryOrClear(expiresAt, clear),
      allowed_models: modelsOrClear(selectedModels, clear),
      self_route_only: selfRouteOnly,
    };
    onSubmit(body);
  };

  return (
    <div className="space-y-5">
      <div>
        <label className={LABEL_CLS}>Name (required)</label>
        <input
          type="text"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="e.g. Production server"
          maxLength={80}
          className={INPUT_CLS}
          autoFocus
        />
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className={LABEL_CLS}>Spend cap (USD)</label>
          <input
            type="number"
            value={limitUsd}
            onChange={(e) => setLimitUsd(e.target.value)}
            placeholder="Unlimited"
            min="0"
            step="0.01"
            className={INPUT_CLS}
          />
        </div>
        <div>
          <label className={LABEL_CLS}>Reset window</label>
          <select
            value={limitReset}
            onChange={(e) => setLimitReset(e.target.value as KeyResetWindow)}
            className={INPUT_CLS}
          >
            {RESET_OPTIONS.map((opt) => (
              <option key={opt.value} value={opt.value}>
                {opt.label}
              </option>
            ))}
          </select>
        </div>
      </div>

      <div className="grid grid-cols-3 gap-3">
        <div>
          <label className={LABEL_CLS}>RPM</label>
          <input
            type="number"
            value={rpm}
            onChange={(e) => setRpm(e.target.value)}
            placeholder="—"
            min="0"
            step="1"
            className={INPUT_CLS}
          />
        </div>
        <div>
          <label className={LABEL_CLS}>ITPM</label>
          <input
            type="number"
            value={itpm}
            onChange={(e) => setItpm(e.target.value)}
            placeholder="—"
            min="0"
            step="1"
            className={INPUT_CLS}
          />
        </div>
        <div>
          <label className={LABEL_CLS}>OTPM</label>
          <input
            type="number"
            value={otpm}
            onChange={(e) => setOtpm(e.target.value)}
            placeholder="—"
            min="0"
            step="1"
            className={INPUT_CLS}
          />
        </div>
      </div>
      <p className="-mt-3 text-xs text-text-tertiary">
        Optional per-minute overrides: requests (RPM), input tokens (ITPM), output tokens (OTPM).
      </p>

      <div>
        <label className={LABEL_CLS}>Expires</label>
        <input
          type="date"
          value={expiresAt}
          onChange={(e) => setExpiresAt(e.target.value)}
          className={INPUT_CLS}
        />
      </div>

      <div>
        <label className={LABEL_CLS}>Allowed models (optional)</label>
        {hasModels ? (
          <div className="rounded-lg border border-border-dim bg-bg-primary">
            <input
              type="text"
              value={modelQuery}
              onChange={(e) => setModelQuery(e.target.value)}
              placeholder="Search models..."
              className="w-full bg-transparent px-3 py-2 text-sm text-text-primary outline-none border-b border-border-dim placeholder:text-text-tertiary/60"
            />
            <div className="max-h-40 overflow-y-auto p-1.5 space-y-0.5">
              {filteredModels.length === 0 ? (
                <p className="px-2 py-2 text-xs text-text-tertiary">No matching models.</p>
              ) : (
                filteredModels.map((id) => {
                  const checked = allowed.includes(id);
                  return (
                    <button
                      key={id}
                      type="button"
                      onClick={() => toggleModel(id)}
                      className="w-full flex items-center gap-2 px-2 py-1.5 rounded-md hover:bg-bg-hover text-left transition-colors"
                    >
                      <span
                        className={`flex items-center justify-center w-4 h-4 rounded border shrink-0 ${
                          checked ? "bg-coral border-coral text-white" : "border-border-subtle"
                        }`}
                      >
                        {checked && <Check size={11} />}
                      </span>
                      <span className="text-xs font-mono text-text-secondary truncate">{id}</span>
                    </button>
                  );
                })
              )}
            </div>
          </div>
        ) : (
          <input
            type="text"
            value={modelText}
            onChange={(e) => setModelText(e.target.value)}
            placeholder="Comma-separated model IDs (leave blank for all)"
            className={INPUT_CLS}
          />
        )}
        <p className="mt-1.5 text-xs text-text-tertiary">
          {allowed.length > 0 && hasModels
            ? `${plural(allowed.length, "model")} selected.`
            : "Leave empty to allow all models."}
        </p>
      </div>

      <button
        type="button"
        onClick={() => setSelfRouteOnly((v) => !v)}
        aria-pressed={selfRouteOnly}
        className={`w-full flex items-start gap-3 p-3 rounded-lg border text-left transition-colors ${
          selfRouteOnly ? "border-teal/50 bg-teal/5" : "border-border-dim hover:bg-bg-hover"
        }`}
      >
        <span
          className={`mt-0.5 flex items-center justify-center w-4 h-4 rounded border shrink-0 ${
            selfRouteOnly ? "bg-teal border-teal text-white" : "border-border-subtle"
          }`}
        >
          {selfRouteOnly && <Check size={11} />}
        </span>
        <span className="min-w-0">
          <span className="block text-sm font-medium text-text-primary">My Machine only — free</span>
          <span className="block text-xs text-text-tertiary mt-0.5">
            Every request on this key routes only to a Darkbloom node you run, and is free. It never
            spends balance or reaches the public fleet.
          </span>
        </span>
      </button>

      <div className="flex gap-3 pt-1">
        <button
          onClick={onCancel}
          disabled={submitting}
          className="flex-1 py-2.5 rounded-lg border border-border-dim text-text-secondary text-sm font-medium hover:bg-bg-hover transition-colors disabled:opacity-50"
        >
          Cancel
        </button>
        <button
          onClick={handleSubmit}
          disabled={!canSubmit}
          className="flex-1 py-2.5 rounded-lg bg-coral text-white text-sm font-semibold hover:opacity-90 transition-all disabled:opacity-50 flex items-center justify-center gap-2"
        >
          {submitting && <Loader2 size={14} className="animate-spin" />}
          {mode === "create" ? "Create key" : "Save changes"}
        </button>
      </div>
    </div>
  );
}
