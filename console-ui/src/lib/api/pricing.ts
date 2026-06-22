import { proxyHeaders } from "../http/proxy-client";
import type { PricingResponse } from "./types";

export async function fetchPricing(): Promise<PricingResponse> {
  const res = await fetch("/api/pricing", { headers: proxyHeaders() });
  if (!res.ok) throw new Error(`Failed to fetch pricing: ${res.status}`);
  return res.json();
}
