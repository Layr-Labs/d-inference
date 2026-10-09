import { NextRequest } from "next/server";
import { proxyStripe } from "@/lib/server/stripe-proxy";

export async function GET(req: NextRequest) {
  return proxyStripe(req, "/v1/billing/stripe/status", { query: "refresh" });
}
