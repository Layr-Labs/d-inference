import { apiError, managementHeaders } from "../http/proxy-client";
import type { ApiKey, CreateKeyBody, UpdateKeyBody, CreatedKey } from "./types";

// API key management. These are account-management calls (Privy access token,
// not the localStorage inference key) routed through the /api/keys proxies.
// The plaintext secret is returned ONLY by createApiKey / rotateApiKey.

export async function listApiKeys(token: string): Promise<ApiKey[]> {
  const res = await fetch("/api/keys", { headers: managementHeaders(token) });
  if (!res.ok) throw await apiError(res, "Failed to load API keys");
  const data = await res.json();
  return Array.isArray(data?.data) ? (data.data as ApiKey[]) : [];
}

export async function createApiKey(token: string, body: CreateKeyBody): Promise<CreatedKey> {
  const res = await fetch("/api/keys", {
    method: "POST",
    headers: managementHeaders(token),
    body: JSON.stringify(body),
  });
  if (!res.ok) throw await apiError(res, "Failed to create API key");
  return res.json();
}

export async function updateApiKey(token: string, id: string, body: UpdateKeyBody): Promise<ApiKey> {
  const res = await fetch(`/api/keys/${encodeURIComponent(id)}`, {
    method: "PATCH",
    headers: managementHeaders(token),
    body: JSON.stringify(body),
  });
  if (!res.ok) throw await apiError(res, "Failed to update API key");
  return res.json();
}

export async function deleteApiKey(token: string, id: string): Promise<void> {
  const res = await fetch(`/api/keys/${encodeURIComponent(id)}`, {
    method: "DELETE",
    headers: managementHeaders(token),
  });
  if (!res.ok) throw await apiError(res, "Failed to revoke API key");
}

export async function rotateApiKey(token: string, id: string): Promise<CreatedKey> {
  const res = await fetch(`/api/keys/${encodeURIComponent(id)}/rotate`, {
    method: "POST",
    headers: managementHeaders(token),
  });
  if (!res.ok) throw await apiError(res, "Failed to rotate API key");
  return res.json();
}
