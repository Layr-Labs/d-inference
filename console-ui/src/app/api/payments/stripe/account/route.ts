import { NextRequest } from "next/server";
import { proxyStripe } from "@/lib/server/stripe-proxy";

export async function DELETE(req: NextRequest) {
  return proxyStripe(req, "/v1/billing/stripe/account", { method: "DELETE" });
}
