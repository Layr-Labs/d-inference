"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  CheckCircle2,
  Layers,
  Loader2,
  Mail,
  Monitor,
  RefreshCw,
  Save,
  Tag,
  Trash2,
} from "lucide-react";
import { useAuth } from "@/hooks/useAuth";
import type { MyProvider, MyProvidersResponse } from "../types";

interface ProviderDiscount {
  account_id?: string;
  provider_key?: string;
  model?: string;
  scope: string;
  discount_bps: number;
  discount_percent: number;
}

interface ProviderEffectivePrice {
  model: string;
  base_input_price: number;
  base_output_price: number;
  input_price: number;
  output_price: number;
  discount_bps: number;
  discount_percent: number;
  discount_scope?: string;
  input_usd: string;
  output_usd: string;
}

interface MyPricingResponse {
  account_id: string;
  discounts: ProviderDiscount[];
  prices: ProviderEffectivePrice[];
  max_discount_percent: number;
}

const SAVE_GLOBAL = "global";
const SAVE_ACCOUNT_MODEL = "account-model";
const SAVE_MACHINE_GLOBAL = "machine-global";
const SAVE_MACHINE_MODEL = "machine-model";
const MACHINE_SET_ERROR = "Link a provider machine before setting a machine discount.";
const MACHINE_CLEAR_ERROR = "Link a provider machine before clearing a machine discount.";

function coordinatorUrl() {
  if (typeof window === "undefined") {
    return process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";
  }
  return (
    localStorage.getItem("darkbloom_coordinator_url") ||
    process.env.NEXT_PUBLIC_COORDINATOR_URL ||
    "https://api.darkbloom.dev"
  );
}

function machineKey(provider: MyProvider) {
  return provider.serial_number || provider.se_public_key || provider.id;
}

function machineLabel(provider: MyProvider) {
  const chip = provider.hardware?.chip_name || "Mac";
  const serial = provider.serial_number || provider.id.slice(0, 8);
  return `${chip} · ${serial}`;
}

function scopeLabel(scope: string) {
  switch (scope) {
    case "machine_model":
      return "Machine model";
    case "machine_global":
      return "Machine default";
    case "account_model":
      return "Account model";
    case "account_global":
      return "Account default";
    default:
      return scope.replaceAll("_", " ");
  }
}

function formatMicroUSD(microUSD: number) {
  return `$${(microUSD / 1_000_000).toFixed(4)}`;
}

function resolveDiscount(discounts: ProviderDiscount[], model: string, providerKey: string) {
  const accountGlobal = discounts.find((d) => !d.provider_key && !d.model);
  const accountModel = discounts.find((d) => !d.provider_key && d.model === model);
  if (!providerKey) return accountModel || accountGlobal || null;
  const machineGlobal = discounts.find((d) => d.provider_key === providerKey && !d.model);
  const machineModel = discounts.find((d) => d.provider_key === providerKey && d.model === model);
  return machineModel || machineGlobal || accountModel || accountGlobal || null;
}

function discountedPrice(base: number, discountBPS: number) {
  if (base <= 0 || discountBPS <= 0) return base;
  return Math.max(1, Math.floor((base * (10_000 - discountBPS)) / 10_000));
}

function DiscountEditor({
  title,
  icon: Icon,
  value,
  onChange,
  onSave,
  onClear,
  saving,
  children,
}: {
  title: string;
  icon: React.ComponentType<{ size?: number; className?: string }>;
  value: string;
  onChange: (value: string) => void;
  onSave: () => void;
  onClear: () => void;
  saving: boolean;
  children?: React.ReactNode;
}) {
  return (
    <div className="rounded-lg bg-bg-secondary p-5 space-y-4">
      <div className="flex items-center gap-2">
        <Icon size={16} className="text-accent-brand" />
        <h2 className="text-sm font-semibold text-text-primary">{title}</h2>
      </div>
      {children}
      <div className="flex flex-col sm:flex-row gap-2">
        <label className="flex-1">
          <span className="block text-xs text-text-tertiary mb-1">Discount percent</span>
          <input
            type="number"
            min={0}
            max={90}
            step={0.01}
            value={value}
            onChange={(e) => onChange(e.target.value)}
            className="w-full rounded-lg border border-border-dim bg-bg-white px-3 py-2 text-sm text-text-primary outline-none focus:border-accent-brand"
          />
        </label>
        <div className="flex gap-2 sm:items-end">
          <button
            onClick={onSave}
            disabled={saving}
            className="inline-flex items-center justify-center gap-1.5 rounded-lg bg-coral px-4 py-2 text-sm font-medium text-white hover:opacity-90 disabled:opacity-50"
          >
            <Save size={14} />
            Save
          </button>
          <button
            onClick={onClear}
            disabled={saving}
            className="inline-flex items-center justify-center gap-1.5 rounded-lg border border-border-dim px-3 py-2 text-sm font-medium text-text-secondary hover:bg-bg-hover disabled:opacity-50"
          >
            <Trash2 size={14} />
            Clear
          </button>
        </div>
      </div>
    </div>
  );
}

export default function ProviderPricingPage() {
  const { ready, authenticated, login, getAccessToken } = useAuth();
  const [data, setData] = useState<MyPricingResponse | null>(null);
  const [providers, setProviders] = useState<MyProvider[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [saving, setSaving] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [globalDiscount, setGlobalDiscount] = useState("");
  const [accountModel, setAccountModel] = useState("");
  const [accountModelDiscount, setAccountModelDiscount] = useState("");
  const [machineGlobalKey, setMachineGlobalKey] = useState("");
  const [machineGlobalDiscount, setMachineGlobalDiscount] = useState("");
  const [machineModelKey, setMachineModelKey] = useState("");
  const [machineModel, setMachineModel] = useState("");
  const [machineModelDiscount, setMachineModelDiscount] = useState("");
  const [previewMachineKey, setPreviewMachineKey] = useState("");

  const modelOptions = useMemo(() => data?.prices.map((p) => p.model).sort() ?? [], [data]);

  const loadPricing = useCallback(async () => {
    setRefreshing(true);
    setError(null);
    try {
      const token = await getAccessToken().catch(() => null);
      if (!token) {
        setError("Not authenticated");
        return;
      }
      const headers = { Authorization: `Bearer ${token}` };
      const [pricingRes, providersRes] = await Promise.all([
        fetch(`${coordinatorUrl()}/v1/pricing/me`, { headers, cache: "no-store" }),
        fetch(`${coordinatorUrl()}/v1/me/providers`, { headers, cache: "no-store" }).catch(() => null),
      ]);
      if (!pricingRes.ok) throw new Error(`pricing: HTTP ${pricingRes.status}`);
      const pricing = (await pricingRes.json()) as MyPricingResponse;
      setData(pricing);
      const accountGlobal = pricing.discounts.find((d) => !d.provider_key && !d.model);
      setGlobalDiscount(accountGlobal ? String(accountGlobal.discount_percent) : "");

      if (providersRes?.ok) {
        const providerData = (await providersRes.json()) as MyProvidersResponse;
        setProviders(providerData.providers || []);
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [getAccessToken]);

  useEffect(() => {
    if (!authenticated) {
      setLoading(false);
      return;
    }
    loadPricing();
  }, [authenticated, loadPricing]);

  useEffect(() => {
    if (modelOptions.length > 0) {
      setAccountModel((current) => current || modelOptions[0]);
      setMachineModel((current) => current || modelOptions[0]);
    }
  }, [modelOptions]);

  useEffect(() => {
    if (providers.length > 0) {
      const first = machineKey(providers[0]);
      setMachineGlobalKey((current) => current || first);
      setMachineModelKey((current) => current || first);
    }
  }, [providers]);

  async function saveDiscount(
    selector: { provider_key?: string; model?: string },
    percentText: string,
    key: string,
  ) {
    const percent = Number(percentText);
    const max = data?.max_discount_percent ?? 90;
    if (!Number.isFinite(percent) || percent < 0 || percent > max) {
      setError(`Discount must be between 0 and ${max}`);
      return;
    }
    setSaving(key);
    setError(null);
    setNotice(null);
    try {
      const token = await getAccessToken();
      const res = await fetch(`${coordinatorUrl()}/v1/pricing/discount`, {
        method: "PUT",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ ...selector, discount_percent: percent }),
      });
      if (!res.ok) throw new Error(await res.text());
      setNotice("Discount saved.");
      await loadPricing();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving("");
    }
  }

  async function clearDiscount(selector: { provider_key?: string; model?: string }, key: string) {
    setSaving(key);
    setError(null);
    setNotice(null);
    try {
      const token = await getAccessToken();
      const res = await fetch(`${coordinatorUrl()}/v1/pricing/discount`, {
        method: "DELETE",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(selector),
      });
      if (!res.ok) throw new Error(await res.text());
      setNotice("Discount cleared.");
      await loadPricing();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving("");
    }
  }

  if (!ready || (loading && authenticated)) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loader2 size={24} className="animate-spin text-accent-brand" />
      </div>
    );
  }

  if (!authenticated) {
    return (
      <div className="max-w-5xl mx-auto p-6">
        <div className="bg-bg-secondary rounded-lg p-6">
          <h1 className="text-2xl font-bold text-text-primary mb-2">Provider Pricing</h1>
          <p className="text-sm text-text-secondary mb-5 max-w-2xl">
            Sign in to set provider discounts and preview effective model prices.
          </p>
          <button
            onClick={login}
            className="inline-flex items-center gap-2 px-6 py-2.5 rounded-lg bg-coral text-white font-medium text-sm hover:opacity-90"
          >
            <Mail size={14} />
            Sign In
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="max-w-6xl mx-auto p-6 space-y-6">
      <div className="flex items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-text-primary">Provider Pricing</h1>
          <p className="text-sm text-text-tertiary mt-0.5">
            Account defaults, model overrides, and machine-specific discounts.
          </p>
        </div>
        <button
          onClick={loadPricing}
          disabled={refreshing}
          className="inline-flex items-center gap-1.5 text-sm text-text-tertiary hover:text-text-primary disabled:opacity-50"
        >
          <RefreshCw size={14} className={refreshing ? "animate-spin" : ""} />
          Refresh
        </button>
      </div>

      {error ? (
        <div className="rounded-lg border border-accent-red/30 bg-accent-red/5 px-4 py-3 text-sm text-accent-red">
          {error}
        </div>
      ) : null}
      {notice ? (
        <div className="rounded-lg border border-accent-green/30 bg-accent-green/5 px-4 py-3 text-sm text-accent-green flex items-center gap-2">
          <CheckCircle2 size={15} />
          {notice}
        </div>
      ) : null}

      <DiscountEditor
        title="Account Default"
        icon={Tag}
        value={globalDiscount}
        onChange={setGlobalDiscount}
        saving={saving === SAVE_GLOBAL}
        onSave={() => saveDiscount({}, globalDiscount, SAVE_GLOBAL)}
        onClear={() => clearDiscount({}, SAVE_GLOBAL)}
      />

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <DiscountEditor
          title="Account Model"
          icon={Layers}
          value={accountModelDiscount}
          onChange={setAccountModelDiscount}
          saving={saving === SAVE_ACCOUNT_MODEL}
          onSave={() => saveDiscount({ model: accountModel }, accountModelDiscount, SAVE_ACCOUNT_MODEL)}
          onClear={() => clearDiscount({ model: accountModel }, SAVE_ACCOUNT_MODEL)}
        >
          <label>
            <span className="block text-xs text-text-tertiary mb-1">Model</span>
            <select
              value={accountModel}
              onChange={(e) => setAccountModel(e.target.value)}
              className="w-full rounded-lg border border-border-dim bg-bg-white px-3 py-2 text-sm text-text-primary outline-none focus:border-accent-brand"
            >
              {modelOptions.map((model) => (
                <option key={model} value={model}>
                  {model}
                </option>
              ))}
            </select>
          </label>
        </DiscountEditor>

        <DiscountEditor
          title="Machine Default"
          icon={Monitor}
          value={machineGlobalDiscount}
          onChange={setMachineGlobalDiscount}
          saving={saving === SAVE_MACHINE_GLOBAL}
          onSave={() => {
            if (!machineGlobalKey) {
              setError(MACHINE_SET_ERROR);
              return;
            }
            saveDiscount({ provider_key: machineGlobalKey }, machineGlobalDiscount, SAVE_MACHINE_GLOBAL);
          }}
          onClear={() => {
            if (!machineGlobalKey) {
              setError(MACHINE_CLEAR_ERROR);
              return;
            }
            clearDiscount({ provider_key: machineGlobalKey }, SAVE_MACHINE_GLOBAL);
          }}
        >
          <label>
            <span className="block text-xs text-text-tertiary mb-1">Machine</span>
            <select
              value={machineGlobalKey}
              onChange={(e) => setMachineGlobalKey(e.target.value)}
              className="w-full rounded-lg border border-border-dim bg-bg-white px-3 py-2 text-sm text-text-primary outline-none focus:border-accent-brand"
            >
              {providers.map((provider) => (
                <option key={provider.id} value={machineKey(provider)}>
                  {machineLabel(provider)}
                </option>
              ))}
            </select>
          </label>
        </DiscountEditor>

        <DiscountEditor
          title="Machine Model"
          icon={Monitor}
          value={machineModelDiscount}
          onChange={setMachineModelDiscount}
          saving={saving === SAVE_MACHINE_MODEL}
          onSave={() => {
            if (!machineModelKey) {
              setError(MACHINE_SET_ERROR);
              return;
            }
            saveDiscount(
              { provider_key: machineModelKey, model: machineModel },
              machineModelDiscount,
              SAVE_MACHINE_MODEL,
            );
          }}
          onClear={() => {
            if (!machineModelKey) {
              setError(MACHINE_CLEAR_ERROR);
              return;
            }
            clearDiscount({ provider_key: machineModelKey, model: machineModel }, SAVE_MACHINE_MODEL);
          }}
        >
          <div className="grid grid-cols-1 gap-3">
            <label>
              <span className="block text-xs text-text-tertiary mb-1">Machine</span>
              <select
                value={machineModelKey}
                onChange={(e) => setMachineModelKey(e.target.value)}
                className="w-full rounded-lg border border-border-dim bg-bg-white px-3 py-2 text-sm text-text-primary outline-none focus:border-accent-brand"
              >
                {providers.map((provider) => (
                  <option key={provider.id} value={machineKey(provider)}>
                    {machineLabel(provider)}
                  </option>
                ))}
              </select>
            </label>
            <label>
              <span className="block text-xs text-text-tertiary mb-1">Model</span>
              <select
                value={machineModel}
                onChange={(e) => setMachineModel(e.target.value)}
                className="w-full rounded-lg border border-border-dim bg-bg-white px-3 py-2 text-sm text-text-primary outline-none focus:border-accent-brand"
              >
                {modelOptions.map((model) => (
                  <option key={model} value={model}>
                    {model}
                  </option>
                ))}
              </select>
            </label>
          </div>
        </DiscountEditor>
      </div>

      <section className="rounded-lg bg-bg-secondary p-5">
        <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3 mb-4">
          <h2 className="text-sm font-semibold text-text-primary">Effective Price Preview</h2>
          <select
            value={previewMachineKey}
            onChange={(e) => setPreviewMachineKey(e.target.value)}
            className="rounded-lg border border-border-dim bg-bg-white px-3 py-2 text-sm text-text-primary outline-none focus:border-accent-brand"
          >
            <option value="">Account pricing</option>
            {providers.map((provider) => (
              <option key={provider.id} value={machineKey(provider)}>
                {machineLabel(provider)}
              </option>
            ))}
          </select>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full min-w-[720px]">
            <thead>
              <tr className="border-b border-border-dim">
                <th className="px-3 py-2 text-left text-xs font-medium text-text-tertiary">Model</th>
                <th className="px-3 py-2 text-right text-xs font-medium text-text-tertiary">Input</th>
                <th className="px-3 py-2 text-right text-xs font-medium text-text-tertiary">Output</th>
                <th className="px-3 py-2 text-right text-xs font-medium text-text-tertiary">Discount</th>
                <th className="px-3 py-2 text-left text-xs font-medium text-text-tertiary">Source</th>
              </tr>
            </thead>
            <tbody>
              {(data?.prices ?? []).map((price) => {
                const discount = resolveDiscount(data?.discounts ?? [], price.model, previewMachineKey);
                const discountBPS =
                  discount?.discount_bps ?? Math.round((discount?.discount_percent ?? 0) * 100);
                const input = discountedPrice(price.base_input_price || price.input_price, discountBPS);
                const output = discountedPrice(price.base_output_price || price.output_price, discountBPS);
                return (
                  <tr key={price.model} className="border-b border-border-dim/50 last:border-0">
                    <td className="px-3 py-2.5 text-xs font-mono text-text-primary">{price.model}</td>
                    <td className="px-3 py-2.5 text-right text-sm text-text-primary">{formatMicroUSD(input)}</td>
                    <td className="px-3 py-2.5 text-right text-sm text-text-primary">{formatMicroUSD(output)}</td>
                    <td className="px-3 py-2.5 text-right text-sm text-text-secondary">
                      {discount ? `${discount.discount_percent.toFixed(2)}%` : "0%"}
                    </td>
                    <td className="px-3 py-2.5 text-xs text-text-tertiary">
                      {discount ? scopeLabel(discount.scope) : "Platform price"}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </section>

      <section className="rounded-lg bg-bg-secondary p-5">
        <h2 className="text-sm font-semibold text-text-primary mb-3">Configured Discounts</h2>
        {(data?.discounts.length ?? 0) === 0 ? (
          <p className="text-sm text-text-tertiary">No provider discounts configured.</p>
        ) : (
          <div className="space-y-2">
            {data?.discounts.map((discount) => (
              <div
                key={`${discount.provider_key || "account"}:${discount.model || "all"}`}
                className="flex flex-col sm:flex-row sm:items-center justify-between gap-2 rounded-lg border border-border-dim bg-bg-white px-3 py-2"
              >
                <div>
                  <p className="text-sm font-medium text-text-primary">{scopeLabel(discount.scope)}</p>
                  <p className="text-xs text-text-tertiary font-mono">
                    {discount.provider_key || "account"} · {discount.model || "all models"}
                  </p>
                </div>
                <p className="text-sm font-semibold text-accent-brand">
                  {discount.discount_percent.toFixed(2)}%
                </p>
              </div>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}
