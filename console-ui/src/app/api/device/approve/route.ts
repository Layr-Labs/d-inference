import { NextRequest } from "next/server";
import { proxyAccount } from "@/lib/server/account-proxy";

export async function POST(req: NextRequest) {
  return proxyAccount(req, "/v1/device/approve", { method: "POST", body: "text" });
}
