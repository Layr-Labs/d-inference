export const ADMIN_TOKEN_STORAGE_KEY = "darkbloom.admin.token";
export const COORDINATOR_URL_STORAGE_KEY = "darkbloom.admin.coordinator_url";

export type JsonPrimitive = string | number | boolean | null;
export type JsonValue = JsonPrimitive | JsonObject | JsonValue[];
export type JsonObject = { [key: string]: JsonValue | undefined };

export type AdminConfig = {
  token: string;
  coordinatorUrl?: string;
};

export type SupportedModel = JsonObject & {
  id: string;
  s3_name?: string;
  display_name?: string;
  model_type?: string;
  size_gb?: number;
  architecture?: string;
  description?: string;
  min_ram_gb?: number;
  active?: boolean;
  weight_hash?: string;
};

export type Release = JsonObject & {
  version: string;
  platform?: string;
  backend?: string;
  binary_hash?: string;
  bundle_hash?: string;
  metallib_hash?: string;
  python_hash?: string;
  runtime_hash?: string;
  template_hashes?: string;
  url?: string;
  changelog?: string;
  active?: boolean;
  created_at?: string;
};

export type InviteCode = JsonObject & {
  code: string;
  amount_usd?: string | number;
  max_uses?: number;
  used_count?: number;
  active?: boolean;
  expires_at?: string | null;
  created_at?: string;
};

export type PriceEntry = JsonObject & {
  model: string;
  input_price?: number;
  output_price?: number;
  input_usd?: string;
  output_usd?: string;
};

export type MetricsSnapshot = JsonObject & {
  counters?: Record<string, number>;
  gauges?: Record<string, number>;
  histograms?: Record<
    string,
    {
      buckets?: number[];
      counts?: number[];
      sum?: number;
      count?: number;
      [key: string]: JsonValue | undefined;
    }
  >;
};

export type CreateInviteCodePayload = {
  code?: string;
  amount_usd: number;
  max_uses?: number;
  expires_at?: string;
};

export type GrantBalancePayload = {
  email: string;
  amount_usd: string | number;
  note?: string;
};

type AdminRequestConfig = Partial<AdminConfig>;

function adminPath(path: string): string {
  const normalized = path.replace(/^\/+/, "");
  return `/api/admin/${normalized}`;
}

function headersFor(config: AdminRequestConfig, init?: RequestInit): Headers {
  const headers = new Headers(init?.headers);
  if (config.token) {
    headers.set("x-admin-token", config.token);
  }
  if (config.coordinatorUrl) {
    headers.set("x-coordinator-url", config.coordinatorUrl);
  }
  return headers;
}

async function parseError(response: Response): Promise<string> {
  const fallback = `request failed with status ${response.status}`;
  const contentType = response.headers.get("content-type") ?? "";

  try {
    if (contentType.includes("application/json")) {
      const payload = (await response.json()) as unknown;
      const message = extractErrorMessage(payload);
      return message || fallback;
    }
    const text = await response.text();
    return text.trim() || fallback;
  } catch {
    return fallback;
  }
}

function extractErrorMessage(value: unknown): string | undefined {
  if (!value || typeof value !== "object") {
    return undefined;
  }

  const record = value as Record<string, unknown>;
  if (typeof record.message === "string") {
    return record.message;
  }
  return extractErrorMessage(record.error);
}

async function requestAdmin(config: AdminRequestConfig, path: string, init?: RequestInit): Promise<Response> {
  const headers = headersFor(config, init);
  const response = await fetch(adminPath(path), {
    ...init,
    headers,
    cache: "no-store",
  });

  if (!response.ok) {
    throw new Error(await parseError(response));
  }
  return response;
}

function jsonInit(method: "POST" | "PUT" | "DELETE", payload: unknown): RequestInit {
  return {
    method,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  };
}

export async function adminJson<T>(config: AdminConfig, path: string, init?: RequestInit): Promise<T> {
  const response = await requestAdmin(config, path, init);
  if (response.status === 204) {
    return undefined as T;
  }
  return (await response.json()) as T;
}

export async function adminText(config: AdminConfig, path: string, init?: RequestInit): Promise<string> {
  const response = await requestAdmin(config, path, init);
  return response.text();
}

export async function initAdminOtp(email: string, coordinatorUrl?: string): Promise<JsonObject> {
  return adminJson<JsonObject>({ token: "", coordinatorUrl }, "auth/init", jsonInit("POST", { email }));
}

export async function verifyAdminOtp(email: string, code: string, coordinatorUrl?: string): Promise<{ token: string; email: string } & JsonObject> {
  return adminJson<{ token: string; email: string } & JsonObject>(
    { token: "", coordinatorUrl },
    "auth/verify",
    jsonInit("POST", { email, code }),
  );
}

export async function listModels(config: AdminConfig): Promise<SupportedModel[]> {
  const response = await adminJson<{ models?: SupportedModel[] }>(config, "models");
  return response.models ?? [];
}

export async function saveModel(config: AdminConfig, model: SupportedModel): Promise<{ status?: string; model?: SupportedModel } & JsonObject> {
  return adminJson<{ status?: string; model?: SupportedModel } & JsonObject>(config, "models", jsonInit("POST", model));
}

export async function deleteModel(config: AdminConfig, id: string): Promise<JsonObject> {
  return adminJson<JsonObject>(config, "models", jsonInit("DELETE", { id }));
}

export async function setPlatformPricing(
  config: AdminConfig,
  model: string,
  inputPrice: number,
  outputPrice: number,
): Promise<JsonObject> {
  return adminJson<JsonObject>(
    config,
    "pricing",
    jsonInit("PUT", { model, input_price: inputPrice, output_price: outputPrice }),
  );
}

export async function listReleases(config: AdminConfig): Promise<Release[]> {
  const response = await adminJson<{ releases?: Release[] }>(config, "releases");
  return response.releases ?? [];
}

export async function deactivateRelease(config: AdminConfig, version: string, platform?: string): Promise<JsonObject> {
  return adminJson<JsonObject>(config, "releases", jsonInit("DELETE", { version, platform }));
}

export async function listInviteCodes(config: AdminConfig): Promise<InviteCode[]> {
  const response = await adminJson<{ invite_codes?: InviteCode[] }>(config, "invite-codes");
  return response.invite_codes ?? [];
}

export async function createInviteCode(config: AdminConfig, payload: CreateInviteCodePayload): Promise<JsonObject> {
  return adminJson<JsonObject>(config, "invite-codes", jsonInit("POST", payload));
}

export async function deactivateInviteCode(config: AdminConfig, code: string): Promise<JsonObject> {
  return adminJson<JsonObject>(config, "invite-codes", jsonInit("DELETE", { code }));
}

export async function grantCredit(config: AdminConfig, payload: GrantBalancePayload): Promise<JsonObject> {
  return adminJson<JsonObject>(config, "credit", jsonInit("POST", payload));
}

export async function grantReward(config: AdminConfig, payload: GrantBalancePayload): Promise<JsonObject> {
  return adminJson<JsonObject>(config, "reward", jsonInit("POST", payload));
}

export async function getMetrics(config: AdminConfig): Promise<MetricsSnapshot> {
  return adminJson<MetricsSnapshot>(config, "metrics");
}

export async function getPrometheusMetrics(config: AdminConfig): Promise<string> {
  return adminText(config, "metrics?format=prom");
}
