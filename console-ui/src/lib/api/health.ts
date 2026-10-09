import { proxyHeaders } from "../http/proxy-client";

export async function healthCheck(): Promise<{ status: string; providers: number }> {
  const res = await fetch("/api/health", { headers: proxyHeaders() });
  if (!res.ok) throw new Error(`Health check failed: ${res.status}`);
  return res.json();
}
