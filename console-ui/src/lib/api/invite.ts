import { proxyHeaders } from "../http/proxy-client";
import type { InviteRedeemResponse } from "./types";

export async function redeemInviteCode(code: string): Promise<InviteRedeemResponse> {
  const res = await fetch("/api/invite/redeem", {
    method: "POST",
    headers: proxyHeaders(),
    body: JSON.stringify({ code }),
  });
  const data = await res.json();
  if (!res.ok) {
    const msg = data?.error?.message || data?.message || `Redemption failed (${res.status})`;
    throw new Error(msg);
  }
  return data;
}
