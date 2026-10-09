import { NextRequest } from "next/server";
import { proxyStripe } from "@/lib/server/stripe-proxy";

export async function POST(req: NextRequest) {
  return proxyStripe(req, "/v1/billing/stripe/dashboard", { method: "POST" });
}
