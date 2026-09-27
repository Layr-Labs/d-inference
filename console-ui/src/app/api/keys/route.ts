import { NextRequest } from "next/server";
import { proxyAccount } from "@/lib/server/account-proxy";

export async function GET(req: NextRequest) {
  return proxyAccount(req, "/v1/keys");
}

export async function POST(req: NextRequest) {
  return proxyAccount(req, "/v1/keys", { method: "POST", body: "text" });
}
