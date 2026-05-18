"use client";

import {
  Activity,
  BadgeDollarSign,
  Box,
  CheckCircle2,
  Coins,
  Copy,
  Gift,
  KeyRound,
  Loader2,
  LogIn,
  LogOut,
  PackageCheck,
  RefreshCw,
  Settings,
  ShieldCheck,
  Tag,
  Trash2,
  XCircle,
  type LucideIcon,
} from "lucide-react";
import { type ReactNode, useEffect, useState } from "react";

import {
  ADMIN_TOKEN_STORAGE_KEY,
  COORDINATOR_URL_STORAGE_KEY,
  type AdminConfig,
  type SupportedModel,
  createInviteCode,
  deactivateInviteCode,
  deactivateRelease,
  deleteModel,
  getMetrics,
  getPrometheusMetrics,
  grantCredit,
  grantReward,
  initAdminOtp,
  listInviteCodes,
  listModels,
  listReleases,
  saveModel,
  setPlatformPricing,
  verifyAdminOtp,
} from "@/lib/admin-api";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { useAdminPrivyAuth } from "@/components/providers/privy-client-provider";
import { cn } from "@/lib/utils";

type SectionId = "auth" | "models" | "pricing" | "releases" | "invites" | "credits" | "metrics";
type LoadKey =
  | "saveSettings"
  | "privyToken"
  | "otpInit"
  | "otpVerify"
  | "models"
  | "saveModel"
  | "deleteModel"
  | "pricing"
  | "releases"
  | "deactivateRelease"
  | "invites"
  | "createInvite"
  | "deactivateInvite"
  | "credit"
  | "reward"
  | "jsonMetrics"
  | "prometheusMetrics";
type Message = { type: "success" | "error"; text: string };
type JsonRecord = Record<string, unknown>;

const sections: Array<{ id: SectionId; label: string; icon: LucideIcon }> = [
  { id: "auth", label: "Auth", icon: ShieldCheck },
  { id: "models", label: "Models", icon: Box },
  { id: "pricing", label: "Pricing", icon: BadgeDollarSign },
  { id: "releases", label: "Releases", icon: PackageCheck },
  { id: "invites", label: "Invite codes", icon: Gift },
  { id: "credits", label: "Credits", icon: Coins },
  { id: "metrics", label: "Metrics", icon: Activity },
];

const emptyModelForm = {
  id: "",
  s3_name: "",
  display_name: "",
  model_type: "text",
  size_gb: "",
  architecture: "",
  description: "",
  min_ram_gb: "",
  active: true,
  weight_hash: "",
};

function textFromError(error: unknown) {
  if (error instanceof Error) return error.message;
  return String(error);
}

function getList(value: unknown, keys: string[]) {
  if (Array.isArray(value)) return value as JsonRecord[];
  if (!value || typeof value !== "object") return [];
  const record = value as JsonRecord;
  for (const key of keys) {
    if (Array.isArray(record[key])) return record[key] as JsonRecord[];
  }
  return [];
}

function valueText(value: unknown) {
  if (value === null || value === undefined) return "";
  if (typeof value === "boolean") return value ? "yes" : "no";
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

function maskToken(token: string) {
  if (!token) return "No token saved";
  if (token.length <= 8) return "Saved token is masked";
  return `${token.slice(0, 4)}...${token.slice(-4)}`;
}

function userEmail(user: unknown) {
  if (!user || typeof user !== "object") return "";
  const record = user as { email?: { address?: string }; linkedAccounts?: Array<{ type?: string; address?: string }> };
  return record.email?.address || record.linkedAccounts?.find((account) => account.type === "email")?.address || "";
}

function formatMicroUsd(value: unknown) {
  if (typeof value !== "number") return valueText(value);
  return `$${(value / 1_000_000).toFixed(2)}`;
}

function parseNumber(value: string) {
  return Number(value.trim());
}

function isPositiveNumber(value: string) {
  return value.trim() !== "" && Number.isFinite(parseNumber(value)) && parseNumber(value) > 0;
}

function isPositiveInteger(value: string) {
  return value.trim() !== "" && Number.isSafeInteger(parseNumber(value)) && parseNumber(value) > 0;
}

function modelToForm(model: JsonRecord) {
  return {
    id: valueText(model.id),
    s3_name: valueText(model.s3_name),
    display_name: valueText(model.display_name),
    model_type: valueText(model.model_type),
    size_gb: valueText(model.size_gb),
    architecture: valueText(model.architecture),
    description: valueText(model.description),
    min_ram_gb: valueText(model.min_ram_gb),
    active: Boolean(model.active),
    weight_hash: valueText(model.weight_hash),
  };
}

function InfoMessage({ message }: { message?: Message }) {
  if (!message) return null;
  const Icon = message.type === "success" ? CheckCircle2 : XCircle;
  return (
    <div
      className={cn(
        "flex items-start gap-2 rounded-2xl border px-3 py-2 text-sm",
        message.type === "success" ? "border-accent/30 bg-accent/10 text-accent-foreground" : "border-destructive/30 bg-destructive/10 text-destructive",
      )}
    >
      <Icon className="mt-0.5 h-4 w-4 shrink-0" />
      <span>{message.text}</span>
    </div>
  );
}

function Field({ id, label, children }: { id: string; label: string; children: ReactNode }) {
  return (
    <div className="grid gap-2">
      <Label htmlFor={id}>{label}</Label>
      {children}
    </div>
  );
}

function LoadingIcon({ show }: { show: boolean }) {
  if (!show) return null;
  return <Loader2 className="h-4 w-4 animate-spin" />;
}

function DataTable({ rows, columns, empty }: { rows: JsonRecord[]; columns: string[]; empty: string }) {
  if (rows.length === 0) {
    return <div className="rounded-2xl border border-dashed border-border p-5 text-sm text-muted">{empty}</div>;
  }

  return (
    <div className="overflow-x-auto rounded-2xl border border-border">
      <table className="w-full min-w-[720px] text-left text-sm">
        <thead className="bg-secondary text-xs uppercase tracking-wide text-muted">
          <tr>
            {columns.map((column) => (
              <th className="px-3 py-2 font-semibold" key={column}>
                {column.replaceAll("_", " ")}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-border">
          {rows.map((row, rowIndex) => (
            <tr key={`${valueText(row.id ?? row.code ?? row.version ?? rowIndex)}-${rowIndex}`}>
              {columns.map((column) => (
                <td className="max-w-[22rem] px-3 py-2 align-top text-foreground" key={column}>
                  <span className="line-clamp-3 break-words font-mono text-xs">{column === "amount_micro_usd" ? formatMicroUsd(row[column]) : valueText(row[column])}</span>
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function JsonBlock({ value, placeholder }: { value: unknown; placeholder: string }) {
  if (value === null || value === undefined || value === "") {
    return <div className="rounded-2xl border border-dashed border-border p-5 text-sm text-muted">{placeholder}</div>;
  }
  return <pre className="max-h-[32rem] overflow-auto rounded-2xl border border-border bg-[#111014] p-4 text-xs leading-6 text-[#f8f3e8]">{typeof value === "string" ? value : JSON.stringify(value, null, 2)}</pre>;
}

export function AdminDashboard() {
  const {
    configured: privyConfigured,
    ready: privyReady,
    authenticated: privyAuthenticated,
    user: privyUser,
    login: privyLogin,
    logout: privyLogout,
    getAccessToken: getPrivyAccessToken,
  } = useAdminPrivyAuth();
  const [activeSection, setActiveSection] = useState<SectionId>("auth");
  const [adminToken, setAdminToken] = useState("");
  const [adminTokenInput, setAdminTokenInput] = useState("");
  const [coordinatorUrl, setCoordinatorUrl] = useState("");
  const [otpEmail, setOtpEmail] = useState("");
  const [otpCode, setOtpCode] = useState("");
  const [messages, setMessages] = useState<Partial<Record<LoadKey, Message>>>({});
  const [loading, setLoading] = useState<Partial<Record<LoadKey, boolean>>>({});
  const [models, setModels] = useState<JsonRecord[]>([]);
  const [modelForm, setModelForm] = useState(emptyModelForm);
  const [deleteModelId, setDeleteModelId] = useState("");
  const [pricing, setPricing] = useState({ model: "", input_price: "", output_price: "" });
  const [releases, setReleases] = useState<JsonRecord[]>([]);
  const [releaseAction, setReleaseAction] = useState({ version: "", platform: "" });
  const [inviteCodes, setInviteCodes] = useState<JsonRecord[]>([]);
  const [inviteForm, setInviteForm] = useState({ code: "", amount_usd: "", max_uses: "", expires_at: "" });
  const [deactivateInviteCodeValue, setDeactivateInviteCodeValue] = useState("");
  const [creditForm, setCreditForm] = useState({ email: "", amount_usd: "", note: "" });
  const [rewardForm, setRewardForm] = useState({ email: "", amount_usd: "", note: "" });
  const [jsonMetrics, setJsonMetrics] = useState<unknown>(null);
  const [prometheusMetrics, setPrometheusMetrics] = useState("");

  useEffect(() => {
    setAdminToken(window.sessionStorage.getItem(ADMIN_TOKEN_STORAGE_KEY) ?? "");
    setCoordinatorUrl(window.localStorage.getItem(COORDINATOR_URL_STORAGE_KEY) ?? "");
  }, []);

  useEffect(() => {
    if (!privyConfigured || !privyReady || !privyAuthenticated) return;
    let cancelled = false;

    getPrivyAccessToken().then((token) => {
      if (cancelled || !token) return;
      setAdminToken(token);
      window.sessionStorage.setItem(ADMIN_TOKEN_STORAGE_KEY, token);
    });

    return () => {
      cancelled = true;
    };
  }, [getPrivyAccessToken, privyAuthenticated, privyConfigured, privyReady]);

  const config = { token: adminToken, coordinatorUrl } satisfies AdminConfig;

  async function run<T>(key: LoadKey, action: () => Promise<T>, success?: string) {
    setLoading((current) => ({ ...current, [key]: true }));
    setMessages((current) => ({ ...current, [key]: undefined }));
    try {
      const result = await action();
      if (success) setMessages((current) => ({ ...current, [key]: { type: "success", text: success } }));
      return result;
    } catch (error) {
      setMessages((current) => ({ ...current, [key]: { type: "error", text: textFromError(error) } }));
      return undefined;
    } finally {
      setLoading((current) => ({ ...current, [key]: false }));
    }
  }

  function saveSettings() {
    const nextToken = adminTokenInput.trim();
    const nextCoordinatorUrl = coordinatorUrl.trim();
    if (nextToken) {
      setAdminToken(nextToken);
      window.sessionStorage.setItem(ADMIN_TOKEN_STORAGE_KEY, nextToken);
      setAdminTokenInput("");
    }
    window.localStorage.setItem(COORDINATOR_URL_STORAGE_KEY, nextCoordinatorUrl);
    setCoordinatorUrl(nextCoordinatorUrl);
    setMessages((current) => ({
      ...current,
      saveSettings: { type: "success", text: nextToken ? "Settings saved for this browser session. Token status is masked." : "Coordinator URL saved locally. Existing session token was not changed." },
    }));
  }

  function clearToken() {
    setAdminToken("");
    setAdminTokenInput("");
    window.sessionStorage.removeItem(ADMIN_TOKEN_STORAGE_KEY);
    setMessages((current) => ({ ...current, saveSettings: { type: "success", text: "Saved token cleared." } }));
  }

  async function handleUsePrivyToken() {
    const token = await run("privyToken", async () => {
      const accessToken = await getPrivyAccessToken();
      if (!accessToken) throw new Error("Privy did not return an access token. Sign in again and retry.");
      return accessToken;
    });
    if (!token) return;
    setAdminToken(token);
    setAdminTokenInput("");
    window.sessionStorage.setItem(ADMIN_TOKEN_STORAGE_KEY, token);
    setMessages((current) => ({ ...current, privyToken: { type: "success", text: "Privy access token saved for this browser session." } }));
  }

  async function handleOtpInit() {
    await run("otpInit", () => initAdminOtp(otpEmail.trim(), coordinatorUrl), "OTP login started. Check the configured admin channel for the code.");
  }

  async function handleOtpVerify() {
    const result = await run("otpVerify", () => verifyAdminOtp(otpEmail.trim(), otpCode.trim(), coordinatorUrl), "OTP verified.");
    if (result && typeof result === "object") {
      const record = result as JsonRecord;
      const token = valueText(record.token ?? record.admin_token ?? record.adminToken ?? record.key);
      if (token) {
        setAdminToken(token);
        setAdminTokenInput("");
        window.sessionStorage.setItem(ADMIN_TOKEN_STORAGE_KEY, token);
        setMessages((current) => ({ ...current, otpVerify: { type: "success", text: "OTP verified and token saved for this browser session. Token status is masked." } }));
      }
    }
  }

  async function handleLoadModels() {
    const result = await run("models", () => listModels(config), "Models loaded.");
    if (result !== undefined) setModels(getList(result, ["models", "data"]));
  }

  async function handleSaveModel() {
    if (!isPositiveNumber(modelForm.size_gb)) {
      setMessages((current) => ({ ...current, saveModel: { type: "error", text: "Size GB must be a positive number." } }));
      return;
    }
    if (!isPositiveInteger(modelForm.min_ram_gb)) {
      setMessages((current) => ({ ...current, saveModel: { type: "error", text: "Minimum RAM GB must be a positive integer." } }));
      return;
    }
    const payload = {
      id: modelForm.id.trim(),
      s3_name: modelForm.s3_name.trim(),
      display_name: modelForm.display_name.trim(),
      model_type: modelForm.model_type.trim(),
      size_gb: parseNumber(modelForm.size_gb),
      architecture: modelForm.architecture.trim(),
      description: modelForm.description.trim(),
      min_ram_gb: Math.trunc(parseNumber(modelForm.min_ram_gb)),
      active: modelForm.active,
      weight_hash: modelForm.weight_hash.trim(),
    } satisfies SupportedModel;
    await run("saveModel", () => saveModel(config, payload), "Model saved.");
  }

  async function handleDeleteModel() {
    await run("deleteModel", () => deleteModel(config, deleteModelId.trim()), "Model deleted.");
  }

  async function handleSetPricing() {
    if (!isPositiveInteger(pricing.input_price) || !isPositiveInteger(pricing.output_price)) {
      setMessages((current) => ({ ...current, pricing: { type: "error", text: "Pricing values must be positive integer micro-USD amounts per 1M tokens." } }));
      return;
    }
    const payload = { model: pricing.model.trim(), input_price: parseNumber(pricing.input_price), output_price: parseNumber(pricing.output_price) };
    await run("pricing", () => setPlatformPricing(config, payload.model, payload.input_price, payload.output_price), "Platform pricing updated.");
  }

  async function handleLoadReleases() {
    const result = await run("releases", () => listReleases(config), "Releases loaded.");
    if (result !== undefined) setReleases(getList(result, ["releases", "data"]));
  }

  async function handleDeactivateRelease() {
    await run(
      "deactivateRelease",
      () => deactivateRelease(config, releaseAction.version.trim(), releaseAction.platform.trim() || undefined),
      "Release deactivated.",
    );
  }

  async function handleLoadInvites() {
    const result = await run("invites", () => listInviteCodes(config), "Invite codes loaded.");
    if (result !== undefined) setInviteCodes(getList(result, ["invite_codes", "codes", "data"]));
  }

  async function handleCreateInvite() {
    if (!isPositiveNumber(inviteForm.amount_usd)) {
      setMessages((current) => ({ ...current, createInvite: { type: "error", text: "Invite amount must be a positive USD value." } }));
      return;
    }
    if (inviteForm.max_uses.trim() && !isPositiveInteger(inviteForm.max_uses)) {
      setMessages((current) => ({ ...current, createInvite: { type: "error", text: "Max uses must be a positive integer when provided." } }));
      return;
    }
    const payload = {
      code: inviteForm.code.trim() || undefined,
      amount_usd: parseNumber(inviteForm.amount_usd),
      max_uses: inviteForm.max_uses.trim() ? Math.trunc(parseNumber(inviteForm.max_uses)) : undefined,
      expires_at: inviteForm.expires_at.trim() || undefined,
    };
    await run("createInvite", () => createInviteCode(config, payload), "Invite code created.");
  }

  async function handleDeactivateInvite() {
    await run("deactivateInvite", () => deactivateInviteCode(config, deactivateInviteCodeValue.trim()), "Invite code deactivated.");
  }

  async function handleGrantCredit() {
    if (!isPositiveNumber(creditForm.amount_usd)) {
      setMessages((current) => ({ ...current, credit: { type: "error", text: "Credit amount must be a positive USD value." } }));
      return;
    }
    const payload = { email: creditForm.email.trim(), amount_usd: creditForm.amount_usd.trim(), note: creditForm.note.trim() || undefined };
    await run("credit", () => grantCredit(config, payload), "Non-withdrawable credit granted.");
  }

  async function handleGrantReward() {
    if (!isPositiveNumber(rewardForm.amount_usd)) {
      setMessages((current) => ({ ...current, reward: { type: "error", text: "Reward amount must be a positive USD value." } }));
      return;
    }
    const payload = { email: rewardForm.email.trim(), amount_usd: rewardForm.amount_usd.trim(), note: rewardForm.note.trim() || undefined };
    await run("reward", () => grantReward(config, payload), "Withdrawable reward granted.");
  }

  async function handleLoadJsonMetrics() {
    const result = await run("jsonMetrics", () => getMetrics(config), "JSON metrics loaded.");
    if (result !== undefined) setJsonMetrics(result);
  }

  async function handleLoadPrometheusMetrics() {
    const result = await run("prometheusMetrics", () => getPrometheusMetrics(config), "Prometheus metrics loaded.");
    if (result !== undefined) setPrometheusMetrics(valueText(result));
  }

  const tokenStatus = maskToken(adminToken);
  const privyEmail = userEmail(privyUser);

  return (
    <main className="min-h-screen px-4 py-6 sm:px-6 lg:px-8">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="grid gap-5 rounded-[2rem] border border-border bg-card/70 p-5 shadow-sm backdrop-blur sm:p-8 lg:grid-cols-[1fr_24rem]">
          <div className="space-y-4">
            <Badge variant="outline" className="w-fit bg-card/80">
              EigenInference admin
            </Badge>
            <div className="space-y-3">
              <h1 className="max-w-3xl text-3xl font-semibold tracking-tight sm:text-5xl">Admin operations console</h1>
              <p className="max-w-2xl text-sm leading-6 text-muted sm:text-base">
                Manage catalog models, billing controls, releases, invite codes, credits, and live metrics without making network calls on first paint.
              </p>
            </div>
          </div>
          <Card className="bg-[#15120f] text-white">
            <CardHeader>
              <CardTitle className="flex items-center gap-2 text-base">
                <KeyRound className="h-4 w-4" />
                Local credentials
              </CardTitle>
              <CardDescription className="text-white/70">Privy tokens stay in session storage and are masked in the UI.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-3 text-sm">
              <div className="flex items-center justify-between gap-3 rounded-2xl bg-white/10 px-3 py-2">
                <span className="text-white/70">Token</span>
                <Badge variant={adminToken ? "default" : "secondary"}>{tokenStatus}</Badge>
              </div>
              <div className="flex items-center justify-between gap-3 rounded-2xl bg-white/10 px-3 py-2">
                <span className="text-white/70">Privy</span>
                <Badge variant={privyAuthenticated ? "default" : "secondary"}>{privyAuthenticated ? "Signed in" : "Signed out"}</Badge>
              </div>
              <div className="break-all rounded-2xl bg-white/10 px-3 py-2 font-mono text-xs text-white/80">{coordinatorUrl || "No coordinator URL saved"}</div>
            </CardContent>
          </Card>
        </section>

        <div className="grid gap-6 lg:grid-cols-[17rem_1fr]">
          <aside className="lg:sticky lg:top-6 lg:h-fit">
            <Card>
              <CardContent className="grid gap-2 p-3">
                {sections.map((section) => {
                  const Icon = section.icon;
                  return (
                    <Button
                      className={cn("justify-start", activeSection === section.id && "bg-primary text-primary-foreground hover:bg-primary/90")}
                      key={section.id}
                      onClick={() => setActiveSection(section.id)}
                      type="button"
                      variant={activeSection === section.id ? "default" : "ghost"}
                    >
                      <Icon className="h-4 w-4" />
                      {section.label}
                    </Button>
                  );
                })}
              </CardContent>
            </Card>
          </aside>

          <div className="space-y-6">
            {activeSection === "auth" && (
              <section className="grid gap-6 xl:grid-cols-2">
                <Card>
                  <CardHeader>
                    <CardTitle>Privy admin login</CardTitle>
                    <CardDescription>Sign in with Privy email auth and use the Privy access token for admin endpoints.</CardDescription>
                  </CardHeader>
                  <CardContent className="space-y-4">
                    {!privyConfigured && (
                      <InfoMessage message={{ type: "error", text: "NEXT_PUBLIC_PRIVY_APP_ID is not configured. Manual admin key login still works." }} />
                    )}
                    <div className="flex flex-wrap items-center gap-3">
                      <Badge variant={privyAuthenticated ? "default" : "secondary"}>
                        {privyAuthenticated ? `Signed in${privyEmail ? ` as ${privyEmail}` : ""}` : "Not signed in"}
                      </Badge>
                      <Badge variant="outline">{privyReady ? "Privy ready" : "Privy loading"}</Badge>
                    </div>
                    <div className="flex flex-wrap gap-3">
                      {!privyAuthenticated ? (
                        <Button disabled={!privyConfigured || !privyReady} onClick={privyLogin} type="button">
                          <LogIn className="h-4 w-4" />
                          Sign in with Privy
                        </Button>
                      ) : (
                        <>
                          <Button disabled={loading.privyToken} onClick={handleUsePrivyToken} type="button">
                            <LoadingIcon show={Boolean(loading.privyToken)} />
                            Use Privy token
                          </Button>
                          <Button onClick={() => privyLogout()} type="button" variant="outline">
                            <LogOut className="h-4 w-4" />
                            Sign out
                          </Button>
                        </>
                      )}
                    </div>
                    <InfoMessage message={messages.privyToken} />
                  </CardContent>
                </Card>

                <Card>
                  <CardHeader>
                    <CardTitle>Manual admin key fallback</CardTitle>
                    <CardDescription>Use this when Privy is unavailable or for dev environments with EIGENINFERENCE_ADMIN_KEY.</CardDescription>
                  </CardHeader>
                  <CardContent className="space-y-4">
                    <Field id="coordinator-url" label="Coordinator URL">
                      <Input id="coordinator-url" onChange={(event) => setCoordinatorUrl(event.target.value)} placeholder="https://api.darkbloom.dev" value={coordinatorUrl} />
                    </Field>
                    <Field id="admin-token" label="Admin token or admin key">
                      <Input id="admin-token" onChange={(event) => setAdminTokenInput(event.target.value)} placeholder="Paste new token or scoped admin key" type="password" value={adminTokenInput} />
                    </Field>
                    <div className="flex flex-wrap items-center gap-3">
                      <Button onClick={saveSettings} type="button">
                        <Settings className="h-4 w-4" />
                        Save locally
                      </Button>
                      <Button onClick={clearToken} type="button" variant="outline">
                        Clear token
                      </Button>
                      <Badge variant="outline">{tokenStatus}</Badge>
                    </div>
                    <InfoMessage message={messages.saveSettings} />
                  </CardContent>
                </Card>

                <Card>
                  <CardHeader>
                    <CardTitle>Coordinator OTP fallback</CardTitle>
                    <CardDescription>Legacy coordinator OTP flow. Prefer the Privy login above for normal admin use.</CardDescription>
                  </CardHeader>
                  <CardContent className="space-y-4">
                    <Field id="otp-email" label="Admin email or identifier">
                      <Input id="otp-email" onChange={(event) => setOtpEmail(event.target.value)} placeholder="admin@example.com" value={otpEmail} />
                    </Field>
                    <div className="flex flex-wrap gap-3">
                      <Button disabled={loading.otpInit} onClick={handleOtpInit} type="button" variant="secondary">
                        <LoadingIcon show={Boolean(loading.otpInit)} />
                        Start OTP
                      </Button>
                    </div>
                    <InfoMessage message={messages.otpInit} />
                    <Field id="otp-code" label="OTP code">
                      <Input id="otp-code" onChange={(event) => setOtpCode(event.target.value)} placeholder="123456" value={otpCode} />
                    </Field>
                    <Button disabled={loading.otpVerify} onClick={handleOtpVerify} type="button">
                      <LoadingIcon show={Boolean(loading.otpVerify)} />
                      Verify OTP
                    </Button>
                    <InfoMessage message={messages.otpVerify} />
                  </CardContent>
                </Card>
              </section>
            )}

            {activeSection === "models" && (
              <section className="space-y-6">
                <Card>
                  <CardHeader>
                    <CardTitle>Models</CardTitle>
                    <CardDescription>Load, add, update, and delete SupportedModel catalog entries.</CardDescription>
                  </CardHeader>
                  <CardContent className="space-y-4">
                    <div className="flex flex-wrap gap-3">
                      <Button disabled={loading.models} onClick={handleLoadModels} type="button">
                        <LoadingIcon show={Boolean(loading.models)} />
                        Load models
                      </Button>
                      <Button onClick={() => setModelForm(emptyModelForm)} type="button" variant="outline">
                        Clear form
                      </Button>
                    </div>
                    <InfoMessage message={messages.models} />
                    <DataTable columns={["id", "display_name", "model_type", "size_gb", "architecture", "min_ram_gb", "active", "weight_hash"]} empty="No models loaded yet." rows={models} />
                    <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
                      {models.map((model, index) => (
                        <Button key={`${valueText(model.id)}-${index}`} onClick={() => setModelForm(modelToForm(model))} size="sm" type="button" variant="outline">
                          <Copy className="h-3.5 w-3.5" />
                          Edit {valueText(model.id) || `model ${index + 1}`}
                        </Button>
                      ))}
                    </div>
                  </CardContent>
                </Card>

                <Card>
                  <CardHeader>
                    <CardTitle>Add or update model</CardTitle>
                    <CardDescription>All SupportedModel fields are included.</CardDescription>
                  </CardHeader>
                  <CardContent className="space-y-4">
                    <div className="grid gap-4 md:grid-cols-2">
                      <Field id="model-id" label="ID">
                        <Input id="model-id" onChange={(event) => setModelForm((current) => ({ ...current, id: event.target.value }))} value={modelForm.id} />
                      </Field>
                      <Field id="model-s3-name" label="S3 name">
                        <Input id="model-s3-name" onChange={(event) => setModelForm((current) => ({ ...current, s3_name: event.target.value }))} value={modelForm.s3_name} />
                      </Field>
                      <Field id="model-display-name" label="Display name">
                        <Input id="model-display-name" onChange={(event) => setModelForm((current) => ({ ...current, display_name: event.target.value }))} value={modelForm.display_name} />
                      </Field>
                      <Field id="model-type" label="Model type">
                        <Input id="model-type" onChange={(event) => setModelForm((current) => ({ ...current, model_type: event.target.value }))} value={modelForm.model_type} />
                      </Field>
                      <Field id="model-size" label="Size GB">
                        <Input id="model-size" inputMode="decimal" onChange={(event) => setModelForm((current) => ({ ...current, size_gb: event.target.value }))} value={modelForm.size_gb} />
                      </Field>
                      <Field id="model-architecture" label="Architecture">
                        <Input id="model-architecture" onChange={(event) => setModelForm((current) => ({ ...current, architecture: event.target.value }))} value={modelForm.architecture} />
                      </Field>
                      <Field id="model-min-ram" label="Minimum RAM GB">
                        <Input id="model-min-ram" inputMode="numeric" onChange={(event) => setModelForm((current) => ({ ...current, min_ram_gb: event.target.value }))} value={modelForm.min_ram_gb} />
                      </Field>
                      <Field id="model-weight-hash" label="Weight hash">
                        <Input id="model-weight-hash" onChange={(event) => setModelForm((current) => ({ ...current, weight_hash: event.target.value }))} value={modelForm.weight_hash} />
                      </Field>
                    </div>
                    <Field id="model-description" label="Description">
                      <Textarea id="model-description" onChange={(event) => setModelForm((current) => ({ ...current, description: event.target.value }))} value={modelForm.description} />
                    </Field>
                    <label className="flex items-center gap-2 text-sm font-medium">
                      <input checked={modelForm.active} className="h-4 w-4 accent-primary" onChange={(event) => setModelForm((current) => ({ ...current, active: event.target.checked }))} type="checkbox" />
                      Active
                    </label>
                    <Button disabled={loading.saveModel} onClick={handleSaveModel} type="button">
                      <LoadingIcon show={Boolean(loading.saveModel)} />
                      Save model
                    </Button>
                    <InfoMessage message={messages.saveModel} />
                  </CardContent>
                </Card>

                <Card>
                  <CardHeader>
                    <CardTitle>Delete model</CardTitle>
                    <CardDescription>Delete a catalog entry by ID.</CardDescription>
                  </CardHeader>
                  <CardContent className="grid gap-4 md:grid-cols-[1fr_auto] md:items-end">
                    <Field id="delete-model-id" label="Model ID">
                      <Input id="delete-model-id" onChange={(event) => setDeleteModelId(event.target.value)} value={deleteModelId} />
                    </Field>
                    <Button disabled={loading.deleteModel} onClick={handleDeleteModel} type="button" variant="destructive">
                      <LoadingIcon show={Boolean(loading.deleteModel)} />
                      <Trash2 className="h-4 w-4" />
                      Delete
                    </Button>
                    <div className="md:col-span-2">
                      <InfoMessage message={messages.deleteModel} />
                    </div>
                  </CardContent>
                </Card>
              </section>
            )}

            {activeSection === "pricing" && (
              <Card>
                <CardHeader>
                  <CardTitle>Platform pricing</CardTitle>
                  <CardDescription>Set the default input and output prices for a model.</CardDescription>
                </CardHeader>
                <CardContent className="space-y-4">
                  <div className="grid gap-4 md:grid-cols-3">
                    <Field id="pricing-model" label="Model">
                      <Input id="pricing-model" onChange={(event) => setPricing((current) => ({ ...current, model: event.target.value }))} value={pricing.model} />
                    </Field>
                    <Field id="input-price" label="Input price (micro-USD per 1M tokens)">
                      <Input id="input-price" inputMode="numeric" onChange={(event) => setPricing((current) => ({ ...current, input_price: event.target.value }))} value={pricing.input_price} />
                    </Field>
                    <Field id="output-price" label="Output price (micro-USD per 1M tokens)">
                      <Input id="output-price" inputMode="numeric" onChange={(event) => setPricing((current) => ({ ...current, output_price: event.target.value }))} value={pricing.output_price} />
                    </Field>
                  </div>
                  <Button disabled={loading.pricing} onClick={handleSetPricing} type="button">
                    <LoadingIcon show={Boolean(loading.pricing)} />
                    <Tag className="h-4 w-4" />
                    Set pricing
                  </Button>
                  <InfoMessage message={messages.pricing} />
                </CardContent>
              </Card>
            )}

            {activeSection === "releases" && (
              <section className="space-y-6">
                <Card>
                  <CardHeader>
                    <CardTitle>Releases</CardTitle>
                    <CardDescription>List all provider releases on demand.</CardDescription>
                  </CardHeader>
                  <CardContent className="space-y-4">
                    <Button disabled={loading.releases} onClick={handleLoadReleases} type="button">
                      <LoadingIcon show={Boolean(loading.releases)} />
                      <RefreshCw className="h-4 w-4" />
                      Load releases
                    </Button>
                    <InfoMessage message={messages.releases} />
                    <DataTable columns={["version", "platform", "backend", "active", "created_at", "url", "binary_hash", "bundle_hash"]} empty="No releases loaded yet." rows={releases} />
                  </CardContent>
                </Card>
                <Card>
                  <CardHeader>
                    <CardTitle>Deactivate release</CardTitle>
                    <CardDescription>Deactivate by version and platform.</CardDescription>
                  </CardHeader>
                  <CardContent className="space-y-4">
                    <div className="grid gap-4 md:grid-cols-2">
                      <Field id="release-version" label="Version">
                        <Input id="release-version" onChange={(event) => setReleaseAction((current) => ({ ...current, version: event.target.value }))} value={releaseAction.version} />
                      </Field>
                      <Field id="release-platform" label="Platform">
                        <Input id="release-platform" onChange={(event) => setReleaseAction((current) => ({ ...current, platform: event.target.value }))} placeholder="macos-arm64" value={releaseAction.platform} />
                      </Field>
                    </div>
                    <Button disabled={loading.deactivateRelease} onClick={handleDeactivateRelease} type="button" variant="destructive">
                      <LoadingIcon show={Boolean(loading.deactivateRelease)} />
                      Deactivate release
                    </Button>
                    <InfoMessage message={messages.deactivateRelease} />
                  </CardContent>
                </Card>
              </section>
            )}

            {activeSection === "invites" && (
              <section className="space-y-6">
                <Card>
                  <CardHeader>
                    <CardTitle>Invite codes</CardTitle>
                    <CardDescription>Create, list, and deactivate invite codes.</CardDescription>
                  </CardHeader>
                  <CardContent className="space-y-4">
                    <Button disabled={loading.invites} onClick={handleLoadInvites} type="button">
                      <LoadingIcon show={Boolean(loading.invites)} />
                      Load invite codes
                    </Button>
                    <InfoMessage message={messages.invites} />
                    <DataTable columns={["code", "amount_usd", "max_uses", "used_count", "active", "created_at", "expires_at"]} empty="No invite codes loaded yet." rows={inviteCodes} />
                  </CardContent>
                </Card>
                <div className="grid gap-6 xl:grid-cols-2">
                  <Card>
                    <CardHeader>
                      <CardTitle>Create invite code</CardTitle>
                      <CardDescription>Code is optional if the API supports generated codes.</CardDescription>
                    </CardHeader>
                    <CardContent className="space-y-4">
                      <Field id="invite-code" label="Code">
                        <Input id="invite-code" onChange={(event) => setInviteForm((current) => ({ ...current, code: event.target.value }))} value={inviteForm.code} />
                      </Field>
                      <Field id="invite-amount" label="Amount USD">
                        <Input id="invite-amount" inputMode="decimal" onChange={(event) => setInviteForm((current) => ({ ...current, amount_usd: event.target.value }))} value={inviteForm.amount_usd} />
                      </Field>
                      <Field id="invite-max-uses" label="Max uses">
                        <Input id="invite-max-uses" inputMode="numeric" onChange={(event) => setInviteForm((current) => ({ ...current, max_uses: event.target.value }))} placeholder="Blank for single-use" value={inviteForm.max_uses} />
                      </Field>
                      <Field id="invite-expires" label="Expires at">
                        <Input id="invite-expires" onChange={(event) => setInviteForm((current) => ({ ...current, expires_at: event.target.value }))} placeholder="2026-12-31T23:59:59Z" value={inviteForm.expires_at} />
                      </Field>
                      <Button disabled={loading.createInvite} onClick={handleCreateInvite} type="button">
                        <LoadingIcon show={Boolean(loading.createInvite)} />
                        Create invite
                      </Button>
                      <InfoMessage message={messages.createInvite} />
                    </CardContent>
                  </Card>

                  <Card>
                    <CardHeader>
                      <CardTitle>Deactivate invite code</CardTitle>
                      <CardDescription>Deactivate by code.</CardDescription>
                    </CardHeader>
                    <CardContent className="space-y-4">
                      <Field id="deactivate-invite" label="Code">
                        <Input id="deactivate-invite" onChange={(event) => setDeactivateInviteCodeValue(event.target.value)} value={deactivateInviteCodeValue} />
                      </Field>
                      <Button disabled={loading.deactivateInvite} onClick={handleDeactivateInvite} type="button" variant="destructive">
                        <LoadingIcon show={Boolean(loading.deactivateInvite)} />
                        Deactivate invite
                      </Button>
                      <InfoMessage message={messages.deactivateInvite} />
                    </CardContent>
                  </Card>
                </div>
              </section>
            )}

            {activeSection === "credits" && (
              <section className="grid gap-6 xl:grid-cols-2">
                <Card>
                  <CardHeader>
                    <CardTitle>Grant credit</CardTitle>
                    <CardDescription>Grant non-withdrawable account credit by email.</CardDescription>
                  </CardHeader>
                  <CardContent className="space-y-4">
                    <Field id="credit-email" label="Email">
                      <Input id="credit-email" onChange={(event) => setCreditForm((current) => ({ ...current, email: event.target.value }))} value={creditForm.email} />
                    </Field>
                    <Field id="credit-amount" label="Amount USD">
                      <Input id="credit-amount" inputMode="decimal" onChange={(event) => setCreditForm((current) => ({ ...current, amount_usd: event.target.value }))} value={creditForm.amount_usd} />
                    </Field>
                    <Field id="credit-note" label="Note">
                      <Textarea id="credit-note" onChange={(event) => setCreditForm((current) => ({ ...current, note: event.target.value }))} value={creditForm.note} />
                    </Field>
                    <Button disabled={loading.credit} onClick={handleGrantCredit} type="button">
                      <LoadingIcon show={Boolean(loading.credit)} />
                      Grant credit
                    </Button>
                    <InfoMessage message={messages.credit} />
                  </CardContent>
                </Card>

                <Card>
                  <CardHeader>
                    <CardTitle>Grant reward</CardTitle>
                    <CardDescription>Grant withdrawable provider reward by email.</CardDescription>
                  </CardHeader>
                  <CardContent className="space-y-4">
                    <Field id="reward-email" label="Email">
                      <Input id="reward-email" onChange={(event) => setRewardForm((current) => ({ ...current, email: event.target.value }))} value={rewardForm.email} />
                    </Field>
                    <Field id="reward-amount" label="Amount USD">
                      <Input id="reward-amount" inputMode="decimal" onChange={(event) => setRewardForm((current) => ({ ...current, amount_usd: event.target.value }))} value={rewardForm.amount_usd} />
                    </Field>
                    <Field id="reward-note" label="Note">
                      <Textarea id="reward-note" onChange={(event) => setRewardForm((current) => ({ ...current, note: event.target.value }))} value={rewardForm.note} />
                    </Field>
                    <Button disabled={loading.reward} onClick={handleGrantReward} type="button">
                      <LoadingIcon show={Boolean(loading.reward)} />
                      Grant reward
                    </Button>
                    <InfoMessage message={messages.reward} />
                  </CardContent>
                </Card>
              </section>
            )}

            {activeSection === "metrics" && (
              <section className="space-y-6">
                <Card>
                  <CardHeader>
                    <CardTitle>Metrics</CardTitle>
                    <CardDescription>Load JSON metrics and Prometheus text only when requested.</CardDescription>
                  </CardHeader>
                  <CardContent className="flex flex-wrap gap-3">
                    <Button disabled={loading.jsonMetrics} onClick={handleLoadJsonMetrics} type="button">
                      <LoadingIcon show={Boolean(loading.jsonMetrics)} />
                      Load JSON metrics
                    </Button>
                    <Button disabled={loading.prometheusMetrics} onClick={handleLoadPrometheusMetrics} type="button" variant="secondary">
                      <LoadingIcon show={Boolean(loading.prometheusMetrics)} />
                      Load Prometheus text
                    </Button>
                  </CardContent>
                </Card>
                <div className="grid gap-6 xl:grid-cols-2">
                  <Card>
                    <CardHeader>
                      <CardTitle>JSON metrics</CardTitle>
                      <InfoMessage message={messages.jsonMetrics} />
                    </CardHeader>
                    <CardContent>
                      <JsonBlock placeholder="No JSON metrics loaded yet." value={jsonMetrics} />
                    </CardContent>
                  </Card>
                  <Card>
                    <CardHeader>
                      <CardTitle>Prometheus metrics</CardTitle>
                      <InfoMessage message={messages.prometheusMetrics} />
                    </CardHeader>
                    <CardContent>
                      <JsonBlock placeholder="No Prometheus metrics loaded yet." value={prometheusMetrics} />
                    </CardContent>
                  </Card>
                </div>
              </section>
            )}
          </div>
        </div>
      </div>
    </main>
  );
}
