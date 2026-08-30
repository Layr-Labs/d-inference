import { NextRequest } from "next/server";
import { proxyPrivateV2Post } from "@/lib/server/private-v2-proxy";

export async function POST(req: NextRequest): Promise<Response> {
  return proxyPrivateV2Post(req, "/v1/private/requests");
}
