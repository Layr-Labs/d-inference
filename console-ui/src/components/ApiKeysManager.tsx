"use client";

import { useCallback, useEffect, useState } from "react";
import {
  Key,
  Plus,
  Copy,
  Check,
  RefreshCw,
  Trash2,
  Power,
  Pencil,
  X,
  Loader2,
  AlertTriangle,
  ShieldCheck,
  Info,
} from "lucide-react";
import { useAuth } from "@/hooks/useAuth";
import { useToastStore } from "@/hooks/useToast";
import { trackEvent } from "@/lib/google-analytics";
import {
  listApiKeys,
  createApiKey,
  updateApiKey,
  deleteApiKey,
  rotateApiKey,
  fetchModels,
  type ApiKey,
  type CreatedKey,
  type KeyResetWindow,
  type UpdateKeyBody,
} from "@/lib/api";

const API_KEY_STORAGE = "darkbloom_api_key";
const CONSOLE_KEY_ID_STORAGE = "darkbloom_console_key_id";

const INPUT_CLS =
  "w-full bg-bg-primary border border-border-dim rounded-lg px-3 py-2 text-sm text-text-primary outline-none focus:border-coral transition-colors placeholder:text-text-tertiary/60";
const LABEL_CLS =
  "block text-xs font-mono text-text-tertiary uppercase tracking-wider mb-1.5";

const SECRET_WARNING =
  "Copy this secret now and store it somewhere safe. For your security, you won't be able to view it again.";
const SHARED_BALANCE_NOTE =
  "All keys draw from your shared account balance. A key's spend cap is a sub-limit on that balance, not extra funds.";
const CONSOLE_KEY_NOTE =
  "This console uses one active key (saved in this browser) for its own chat and test calls. It's provisioned automatically; you can also point it at a new key below.";

const RESET_OPTIONS: { value: KeyResetWindow; label: string }[] = [
  { value: "none", label: "Lifetime (no reset)" },
  { value: "daily", label: "Daily" },
  { value: "weekly", label: "Weekly" },
  { value: "monthly", label: "Monthly" },
];

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

function formatUsd(n: number, decimals = 2): string {
  return `$${n.toFixed(decimals)}`;
}

function formatCount(n: number): string {
  return n.toLocaleString();
}

function plural(n: number, word: string): string {
  return `${n} ${word}${n === 1 ? "" : "s"}`;
}

function usageBarColor(pct: number): string {
  if (pct >= 100) return "bg-accent-red";
  if (pct >= 75) return "bg-accent-amber";
  return "bg-teal";
}

function windowLabel(reset: KeyResetWindow): string {
  switch (reset) {
    case "daily":
      return "Daily";
    case "weekly":
      return "Weekly";
    case "monthly":
      return "Monthly";
    default:
      return "Lifetime";
  }
}

function isExpired(key: ApiKey): boolean {
  if (!key.expires_at) return false;
  const t = new Date(key.expires_at).getTime();
  return !Number.isNaN(t) && t < Date.now();
}

function keyStatus(key: ApiKey): { label: string; cls: string } {
  if (key.disabled) {
    return { label: "Disabled", cls: "text-text-tertiary bg-bg-tertiary border-border-subtle/40" };
  }
  if (isExpired(key)) {
    return { label: "Expired", cls: "text-accent-red bg-accent-red-dim border-accent-red/25" };
  }
  return { label: "Active", cls: "text-teal bg-teal/10 border-teal/30" };
}

function relativeTime(iso?: string): string {
  if (!iso) return "Never";
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return "Never";
  const diff = Date.now() - t;
  if (diff < 60_000) return "just now";
  const min = Math.floor(diff / 60_000);
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.floor(hr / 24);
  if (day < 30) return `${day}d ago`;
  const mo = Math.floor(day / 30);
  if (mo < 12) return `${mo}mo ago`;
  return `${Math.floor(mo / 12)}y ago`;
}

function numOrClear(raw: string, clear: boolean): number | null | undefined {
  const v = raw.trim();
  if (!v) return clear ? null : undefined;
  const n = Number(v);
  // Spend cap: 0 is a valid zero-dollar cap (the key can't spend), so accept
  // any non-negative finite value. Empty string clears (on edit).
  return Number.isFinite(n) && n >= 0 ? n : undefined;
}

function intOrClear(raw: string, clear: boolean): number | null | undefined {
  const v = raw.trim();
  if (!v) return clear ? null : undefined;
  const n = Math.floor(Number(v));
  return Number.isFinite(n) && n > 0 ? n : undefined;
}

function expiryOrClear(raw: string, clear: boolean): string | null | undefined {
  const v = raw.trim();
  if (!v) return clear ? null : undefined;
  const d = new Date(`${v}T23:59:59Z`);
  return Number.isNaN(d.getTime()) ? undefined : d.toISOString();
}

function modelsOrClear(list: string[], clear: boolean): string[] | null | undefined {
  if (list.length > 0) return list;
  return clear ? null : undefined;
}

// ---------------------------------------------------------------------------
// Modal shell
// ---------------------------------------------------------------------------

function Modal({
  open,
  onClose,
  title,
  children,
  maxWidth = "max-w-md",
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  children: React.ReactNode;
  maxWidth?: string;
}) {
  useEffect(() => {
    if (!open) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", handler);
    return () => document.removeEventListener("keydown", handler);
  }, [open, onClose]);

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-3 sm:p-4">
      <div className="absolute inset-0 bg-ink/40 backdrop-blur-sm" onClick={onClose} />
      <div
        className={`relative w-full ${maxWidth} max-h-[88vh] overflow-y-auto rounded-2xl bg-bg-white border border-border-dim shadow-xl`}
      >
        <div className="sticky top-0 z-10 flex items-center justify-between bg-bg-white px-5 py-4 border-b border-border-dim">
          <h3 className="text-base font-semibold text-text-primary">{title}</h3>
          <button
            onClick={onClose}
            className="p-1.5 rounded-lg hover:bg-bg-hover text-text-tertiary transition-colors"
            aria-label="Close"
          >
            <X size={16} />
          </button>
        </div>
        <div className="px-5 py-5">{children}</div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Key create / edit form
// ---------------------------------------------------------------------------

function KeyForm({
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

// ---------------------------------------------------------------------------
// Secret reveal (shown once after create / rotate)
// ---------------------------------------------------------------------------

function SecretReveal({
  created,
  alreadyConsole,
  onSetConsole,
  onClose,
}: {
  created: CreatedKey;
  alreadyConsole: boolean;
  onSetConsole: () => void;
  onClose: () => void;
}) {
  const [copied, setCopied] = useState(false);
  const [didSet, setDidSet] = useState(false);

  const copy = () => {
    navigator.clipboard.writeText(created.key);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="space-y-4">
      <div className="flex items-start gap-2.5 rounded-lg bg-accent-amber-dim border border-accent-amber/25 px-3.5 py-3">
        <AlertTriangle size={16} className="text-accent-amber shrink-0 mt-0.5" />
        <p className="text-sm text-text-secondary leading-relaxed">{SECRET_WARNING}</p>
      </div>

      <div>
        <label className={LABEL_CLS}>{created.data.name || "API key"}</label>
        <div className="flex items-stretch gap-2">
          <code className="flex-1 min-w-0 break-all rounded-lg bg-bg-primary border border-border-dim px-3 py-2.5 text-xs font-mono text-text-primary">
            {created.key}
          </code>
          <button
            onClick={copy}
            className="shrink-0 px-3 rounded-lg border border-border-dim text-text-secondary hover:bg-bg-hover transition-colors flex items-center gap-1.5 text-xs font-medium"
          >
            {copied ? <Check size={14} className="text-accent-green" /> : <Copy size={14} />}
            {copied ? "Copied" : "Copy"}
          </button>
        </div>
      </div>

      {!alreadyConsole && (
        <button
          onClick={() => {
            onSetConsole();
            setDidSet(true);
          }}
          disabled={didSet}
          className="w-full flex items-center justify-center gap-2 py-2.5 rounded-lg border border-border-dim text-sm font-medium text-text-secondary hover:bg-bg-hover transition-colors disabled:opacity-60"
        >
          {didSet ? <Check size={14} className="text-accent-green" /> : <Key size={14} />}
          {didSet ? "Set as this console's key" : "Use as this console's key"}
        </button>
      )}

      <button
        onClick={onClose}
        className="w-full py-2.5 rounded-lg bg-coral text-white text-sm font-semibold hover:opacity-90 transition-all"
      >
        Done
      </button>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Confirm dialog
// ---------------------------------------------------------------------------

function ConfirmBody({
  message,
  confirmLabel,
  danger,
  busy,
  onConfirm,
  onCancel,
}: {
  message: string;
  confirmLabel: string;
  danger?: boolean;
  busy: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  return (
    <div className="space-y-5">
      <p className="text-sm text-text-secondary leading-relaxed">{message}</p>
      <div className="flex gap-3">
        <button
          onClick={onCancel}
          disabled={busy}
          className="flex-1 py-2.5 rounded-lg border border-border-dim text-text-secondary text-sm font-medium hover:bg-bg-hover transition-colors disabled:opacity-50"
        >
          Cancel
        </button>
        <button
          onClick={onConfirm}
          disabled={busy}
          className={`flex-1 py-2.5 rounded-lg text-white text-sm font-semibold hover:opacity-90 transition-all disabled:opacity-50 flex items-center justify-center gap-2 ${
            danger ? "bg-accent-red" : "bg-coral"
          }`}
        >
          {busy && <Loader2 size={14} className="animate-spin" />}
          {confirmLabel}
        </button>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Key card
// ---------------------------------------------------------------------------

function KeyChip({ label }: { label: string }) {
  return (
    <span className="text-[10px] font-mono uppercase tracking-wide text-text-tertiary bg-bg-tertiary border border-border-dim rounded px-1.5 py-0.5">
      {label}
    </span>
  );
}

function UsageBar({ keyData }: { keyData: ApiKey }) {
  const limited = keyData.limit_usd != null && keyData.limit_usd > 0;
  const pct = limited ? Math.min(100, (keyData.usage_usd / (keyData.limit_usd as number)) * 100) : 0;
  const barColor = usageBarColor(pct);

  return (
    <div className="mt-3">
      <div className="flex items-center justify-between mb-1.5 text-xs">
        <span className="text-text-tertiary">
          {limited ? (
            <>
              <span className="font-mono text-text-secondary">{formatUsd(keyData.usage_usd, 4)}</span>
              {" / "}
              <span className="font-mono">{formatUsd(keyData.limit_usd as number)}</span>
            </>
          ) : (
            <>
              <span className="font-mono text-text-secondary">{formatUsd(keyData.usage_usd, 4)}</span>
              {" used · Unlimited"}
            </>
          )}
        </span>
        <KeyChip label={windowLabel(keyData.limit_reset)} />
      </div>
      <div className="h-1.5 rounded-full bg-bg-tertiary overflow-hidden">
        {limited ? (
          <div className={`h-full rounded-full ${barColor}`} style={{ width: `${pct}%` }} />
        ) : (
          <div className="h-full rounded-full bg-border-subtle/40" style={{ width: "100%" }} />
        )}
      </div>
    </div>
  );
}

function IconAction({
  icon: Icon,
  title,
  onClick,
  disabled,
  danger,
}: {
  icon: typeof Key;
  title: string;
  onClick: () => void;
  disabled?: boolean;
  danger?: boolean;
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      title={title}
      aria-label={title}
      className={`p-2 rounded-lg hover:bg-bg-hover transition-colors disabled:opacity-40 ${
        danger ? "text-text-tertiary hover:text-accent-red" : "text-text-tertiary hover:text-text-secondary"
      }`}
    >
      <Icon size={15} />
    </button>
  );
}

function KeyCard({
  keyData,
  isConsole,
  busy,
  onToggle,
  onEdit,
  onRotate,
  onDelete,
}: {
  keyData: ApiKey;
  isConsole: boolean;
  busy: boolean;
  onToggle: () => void;
  onEdit: () => void;
  onRotate: () => void;
  onDelete: () => void;
}) {
  const status = keyStatus(keyData);

  return (
    <div className="rounded-xl border border-border-dim bg-bg-white p-4 shadow-sm">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <span className="text-sm font-semibold text-text-primary truncate">{keyData.name || "Untitled key"}</span>
            <span
              className={`text-[10px] font-mono uppercase tracking-wide rounded border px-1.5 py-0.5 ${status.cls}`}
            >
              {status.label}
            </span>
            {isConsole && (
              <span className="text-[10px] font-mono uppercase tracking-wide text-coral bg-coral-light border border-coral/30 rounded px-1.5 py-0.5">
                Console key
              </span>
            )}
          </div>
          <p className="mt-1 text-xs font-mono text-text-tertiary truncate">{keyData.label}</p>
        </div>
        <div className="flex items-center shrink-0">
          {busy ? (
            <Loader2 size={15} className="animate-spin text-text-tertiary m-2" />
          ) : (
            <>
              <IconAction
                icon={Power}
                title={keyData.disabled ? "Enable key" : "Disable key"}
                onClick={onToggle}
              />
              <IconAction icon={Pencil} title="Edit limits" onClick={onEdit} />
              <IconAction icon={RefreshCw} title="Rotate secret" onClick={onRotate} />
              <IconAction icon={Trash2} title="Revoke key" onClick={onDelete} danger />
            </>
          )}
        </div>
      </div>

      <UsageBar keyData={keyData} />

      <div className="mt-3 flex items-center gap-2 flex-wrap">
        <span className="text-xs text-text-tertiary">
          Last used <span className="text-text-secondary">{relativeTime(keyData.last_used_at)}</span>
        </span>
        <span className="text-text-tertiary/40">·</span>
        <span className="text-xs text-text-tertiary">
          Created <span className="text-text-secondary">{relativeTime(keyData.created_at)}</span>
        </span>
        {keyData.expires_at && (
          <>
            <span className="text-text-tertiary/40">·</span>
            <span className="text-xs text-text-tertiary">
              {isExpired(keyData) ? "Expired " : "Expires "}
              <span className="text-text-secondary">
                {new Date(keyData.expires_at).toLocaleDateString()}
              </span>
            </span>
          </>
        )}
      </div>

      {(keyData.rpm_limit || keyData.itpm_limit || keyData.otpm_limit ||
        (keyData.allowed_models && keyData.allowed_models.length > 0)) && (
        <div className="mt-3 flex items-center gap-1.5 flex-wrap">
          {keyData.rpm_limit ? <KeyChip label={`RPM ${formatCount(keyData.rpm_limit)}`} /> : null}
          {keyData.itpm_limit ? <KeyChip label={`ITPM ${formatCount(keyData.itpm_limit)}`} /> : null}
          {keyData.otpm_limit ? <KeyChip label={`OTPM ${formatCount(keyData.otpm_limit)}`} /> : null}
          {keyData.allowed_models && keyData.allowed_models.length > 0 ? (
            <span
              title={keyData.allowed_models.join(", ")}
              className="text-[10px] font-mono uppercase tracking-wide text-accent-brand bg-accent-brand-dim border border-accent-brand/25 rounded px-1.5 py-0.5"
            >
              {keyData.allowed_models.length} model{keyData.allowed_models.length === 1 ? "" : "s"}
            </span>
          ) : null}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Manager
// ---------------------------------------------------------------------------

type SecretState = { created: CreatedKey; alreadyConsole: boolean };
type ConfirmState = { kind: "rotate" | "delete"; key: ApiKey };

export function ApiKeysManager({ onConsoleKeyChange }: { onConsoleKeyChange?: (key: string) => void }) {
  const { authenticated, login, getAccessToken } = useAuth();
  const addToast = useToastStore((s) => s.addToast);

  const [keys, setKeys] = useState<ApiKey[]>([]);
  const [models, setModels] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [createOpen, setCreateOpen] = useState(false);
  const [editing, setEditing] = useState<ApiKey | null>(null);
  const [secret, setSecret] = useState<SecretState | null>(null);
  const [confirm, setConfirm] = useState<ConfirmState | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [consoleKeyId, setConsoleKeyId] = useState<string | null>(null);

  useEffect(() => {
    if (typeof window !== "undefined") {
      setConsoleKeyId(localStorage.getItem(CONSOLE_KEY_ID_STORAGE));
    }
  }, []);

  const requireToken = useCallback(async (): Promise<string | null> => {
    const token = await getAccessToken().catch(() => null);
    if (!token) addToast("Please sign in to manage API keys", "error");
    return token;
  }, [getAccessToken, addToast]);

  const fetchKeys = useCallback(async (token: string) => {
    const list = await listApiKeys(token);
    setKeys(list);
  }, []);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const token = await getAccessToken().catch(() => null);
      if (!token) {
        setKeys([]);
        setError("Sign in to view your API keys.");
        return;
      }
      await fetchKeys(token);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, [getAccessToken, fetchKeys]);

  useEffect(() => {
    if (!authenticated) {
      setLoading(false);
      setKeys([]);
      return;
    }
    void load();
  }, [authenticated, load]);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const ms = await fetchModels();
        if (!cancelled) setModels(ms.map((m) => m.id).filter(Boolean));
      } catch {
        // Models are optional — the form falls back to a free-text input.
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const setAsConsoleKey = useCallback(
    (created: CreatedKey) => {
      if (typeof window === "undefined") return;
      localStorage.setItem(API_KEY_STORAGE, created.key);
      localStorage.setItem(CONSOLE_KEY_ID_STORAGE, created.data.id);
      setConsoleKeyId(created.data.id);
      onConsoleKeyChange?.(created.key);
      addToast("This key is now your console key", "success");
    },
    [onConsoleKeyChange, addToast],
  );

  const handleCreate = useCallback(
    async (body: UpdateKeyBody) => {
      const token = await requireToken();
      if (!token) return;
      setSubmitting(true);
      try {
        const created = await createApiKey(token, body);
        trackEvent("key_create", { has_limit: body.limit_usd != null });
        setCreateOpen(false);
        setSecret({ created, alreadyConsole: false });
        await fetchKeys(token);
      } catch (e) {
        addToast((e as Error).message, "error");
      } finally {
        setSubmitting(false);
      }
    },
    [requireToken, fetchKeys, addToast],
  );

  const handleEdit = useCallback(
    async (body: UpdateKeyBody) => {
      if (!editing) return;
      const token = await requireToken();
      if (!token) return;
      setSubmitting(true);
      try {
        await updateApiKey(token, editing.id, body);
        trackEvent("key_update");
        setEditing(null);
        addToast("Key updated", "success");
        await fetchKeys(token);
      } catch (e) {
        addToast((e as Error).message, "error");
      } finally {
        setSubmitting(false);
      }
    },
    [editing, requireToken, fetchKeys, addToast],
  );

  const handleToggle = useCallback(
    async (k: ApiKey) => {
      const token = await requireToken();
      if (!token) return;
      setBusyId(k.id);
      try {
        await updateApiKey(token, k.id, { disabled: !k.disabled });
        addToast(k.disabled ? "Key enabled" : "Key disabled", "success");
        await fetchKeys(token);
      } catch (e) {
        addToast((e as Error).message, "error");
      } finally {
        setBusyId(null);
      }
    },
    [requireToken, fetchKeys, addToast],
  );

  const handleRotate = useCallback(
    async (k: ApiKey) => {
      const token = await requireToken();
      if (!token) return;
      setBusyId(k.id);
      try {
        const created = await rotateApiKey(token, k.id);
        trackEvent("key_rotate");
        const isConsole = consoleKeyId === k.id;
        if (isConsole && typeof window !== "undefined") {
          // Rotation mints a NEW key id and deletes the old one, so re-point the
          // console-key mapping at the new id as well as the new secret —
          // otherwise the badge and future console-key actions track a deleted id.
          localStorage.setItem(API_KEY_STORAGE, created.key);
          localStorage.setItem(CONSOLE_KEY_ID_STORAGE, created.data.id);
          setConsoleKeyId(created.data.id);
          onConsoleKeyChange?.(created.key);
        }
        setConfirm(null);
        setSecret({ created, alreadyConsole: isConsole });
        await fetchKeys(token);
      } catch (e) {
        addToast((e as Error).message, "error");
      } finally {
        setBusyId(null);
      }
    },
    [requireToken, fetchKeys, addToast, consoleKeyId, onConsoleKeyChange],
  );

  const handleDelete = useCallback(
    async (k: ApiKey) => {
      const token = await requireToken();
      if (!token) return;
      setBusyId(k.id);
      try {
        await deleteApiKey(token, k.id);
        trackEvent("key_delete");
        if (consoleKeyId === k.id && typeof window !== "undefined") {
          localStorage.removeItem(API_KEY_STORAGE);
          localStorage.removeItem(CONSOLE_KEY_ID_STORAGE);
          setConsoleKeyId(null);
          onConsoleKeyChange?.("");
          window.dispatchEvent(new Event("darkbloom-key-expired"));
          addToast("Console key revoked — a new one will be provisioned automatically", "info");
        } else {
          addToast("Key revoked", "success");
        }
        setConfirm(null);
        await fetchKeys(token);
      } catch (e) {
        addToast((e as Error).message, "error");
      } finally {
        setBusyId(null);
      }
    },
    [requireToken, fetchKeys, addToast, consoleKeyId, onConsoleKeyChange],
  );

  const confirmBusy = confirm ? busyId === confirm.key.id : false;

  let body: React.ReactNode;
  if (!authenticated) {
    body = (
      <div className="rounded-xl bg-bg-secondary shadow-sm p-6 text-center">
        <Key size={20} className="text-text-tertiary mx-auto mb-3" />
        <p className="text-sm text-text-secondary mb-4">Sign in to create and manage your API keys.</p>
        <button
          onClick={login}
          className="inline-flex items-center gap-2 px-5 py-2.5 rounded-lg bg-coral text-white text-sm font-medium hover:opacity-90 transition-all"
        >
          Sign In
        </button>
      </div>
    );
  } else if (loading) {
    body = (
      <div className="flex items-center justify-center py-12">
        <Loader2 size={20} className="animate-spin text-accent-brand" />
      </div>
    );
  } else if (error) {
    body = (
      <div className="rounded-xl bg-bg-secondary shadow-sm p-6 text-center">
        <p className="text-sm text-accent-red mb-3">{error}</p>
        <button
          onClick={() => void load()}
          className="inline-flex items-center gap-2 px-4 py-2 rounded-lg border border-border-dim text-text-secondary text-sm font-medium hover:bg-bg-hover transition-colors"
        >
          <RefreshCw size={14} />
          Retry
        </button>
      </div>
    );
  } else if (keys.length === 0) {
    body = (
      <div className="rounded-xl bg-bg-secondary shadow-sm p-8 text-center">
        <Key size={22} className="text-text-tertiary mx-auto mb-3" />
        <p className="text-sm text-text-primary font-medium mb-1">No API keys yet</p>
        <p className="text-sm text-text-tertiary mb-4">
          Create a named key to start using the Darkbloom API.
        </p>
        <button
          onClick={() => setCreateOpen(true)}
          className="inline-flex items-center gap-2 px-4 py-2 rounded-lg bg-coral text-white text-sm font-medium hover:opacity-90 transition-all"
        >
          <Plus size={15} />
          Create your first key
        </button>
      </div>
    );
  } else {
    body = (
      <div className="space-y-3">
        {keys.map((k) => (
          <KeyCard
            key={k.id}
            keyData={k}
            isConsole={consoleKeyId === k.id}
            busy={busyId === k.id}
            onToggle={() => handleToggle(k)}
            onEdit={() => setEditing(k)}
            onRotate={() => setConfirm({ kind: "rotate", key: k })}
            onDelete={() => setConfirm({ kind: "delete", key: k })}
          />
        ))}
      </div>
    );
  }

  return (
    <section>
      <div className="flex items-center justify-between mb-4 gap-3">
        <h2 className="text-lg font-semibold text-text-primary">API Keys</h2>
        {authenticated && (
          <button
            onClick={() => setCreateOpen(true)}
            className="flex items-center gap-2 px-4 py-2 rounded-lg bg-coral text-white text-sm font-medium hover:opacity-90 transition-all"
          >
            <Plus size={15} />
            New key
          </button>
        )}
      </div>

      <div className="rounded-xl bg-accent-brand/5 border border-accent-brand/15 px-4 py-3 mb-4 space-y-2">
        <div className="flex items-start gap-2.5">
          <Info size={15} className="text-accent-brand shrink-0 mt-0.5" />
          <p className="text-xs text-text-secondary leading-relaxed">{SHARED_BALANCE_NOTE}</p>
        </div>
        <div className="flex items-start gap-2.5">
          <ShieldCheck size={15} className="text-accent-brand shrink-0 mt-0.5" />
          <p className="text-xs text-text-secondary leading-relaxed">{CONSOLE_KEY_NOTE}</p>
        </div>
      </div>

      {body}

      {/* Create modal */}
      <Modal open={createOpen} onClose={() => !submitting && setCreateOpen(false)} title="Create API key">
        <KeyForm
          mode="create"
          models={models}
          submitting={submitting}
          onCancel={() => setCreateOpen(false)}
          onSubmit={handleCreate}
        />
      </Modal>

      {/* Edit modal */}
      <Modal open={!!editing} onClose={() => !submitting && setEditing(null)} title="Edit API key">
        {editing && (
          <KeyForm
            key={editing.id}
            mode="edit"
            initial={editing}
            models={models}
            submitting={submitting}
            onCancel={() => setEditing(null)}
            onSubmit={handleEdit}
          />
        )}
      </Modal>

      {/* Secret reveal modal */}
      <Modal open={!!secret} onClose={() => setSecret(null)} title="Save your API key">
        {secret && (
          <SecretReveal
            created={secret.created}
            alreadyConsole={secret.alreadyConsole}
            onSetConsole={() => setAsConsoleKey(secret.created)}
            onClose={() => setSecret(null)}
          />
        )}
      </Modal>

      {/* Confirm modal */}
      <Modal
        open={!!confirm}
        onClose={() => !confirmBusy && setConfirm(null)}
        title={confirm?.kind === "delete" ? "Revoke API key" : "Rotate API key"}
      >
        {confirm && (
          <ConfirmBody
            message={
              confirm.kind === "delete"
                ? `Revoke "${confirm.key.name || "this key"}"? Any application using it will stop working immediately. This cannot be undone.`
                : `Rotate "${confirm.key.name || "this key"}"? The current secret is revoked immediately and a new one is issued. Update anything using the old secret.`
            }
            confirmLabel={confirm.kind === "delete" ? "Revoke key" : "Rotate key"}
            danger={confirm.kind === "delete"}
            busy={confirmBusy}
            onCancel={() => setConfirm(null)}
            onConfirm={() => (confirm.kind === "delete" ? handleDelete(confirm.key) : handleRotate(confirm.key))}
          />
        )}
      </Modal>
    </section>
  );
}
