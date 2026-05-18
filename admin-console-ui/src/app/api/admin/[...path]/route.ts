import type { NextRequest } from "next/server";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type RouteContext = {
  params: Promise<{ path?: string[] }>;
};

const DEFAULT_COORDINATOR_URL = "https://api.darkbloom.dev";
const DEFAULT_ALLOWED_COORDINATORS = [DEFAULT_COORDINATOR_URL, "https://api.dev.darkbloom.xyz"];

function configuredCoordinatorUrls(): string[] {
  return [
    ...DEFAULT_ALLOWED_COORDINATORS,
    process.env.DARKBLOOM_COORDINATOR_URL,
    process.env.NEXT_PUBLIC_COORDINATOR_URL,
    ...(process.env.ADMIN_CONSOLE_ALLOWED_COORDINATORS ?? "").split(","),
  ].filter((value): value is string => Boolean(value && value.trim()));
}

function originFor(value: string): string | undefined {
  try {
    const url = new URL(value.trim());
    if (url.protocol !== "http:" && url.protocol !== "https:") {
      return undefined;
    }
    return url.origin;
  } catch {
    return undefined;
  }
}

function isLocalDevelopmentHost(hostname: string): boolean {
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1";
}

function isAllowedCoordinator(url: URL): boolean {
  const allowedOrigins = new Set(configuredCoordinatorUrls().map(originFor).filter((origin): origin is string => Boolean(origin)));
  if (allowedOrigins.has(url.origin)) {
    return true;
  }
  return process.env.NODE_ENV !== "production" && isLocalDevelopmentHost(url.hostname);
}

function coordinatorBase(request: NextRequest): string | Response {
  const configured =
    request.headers.get("x-coordinator-url") ||
    process.env.DARKBLOOM_COORDINATOR_URL ||
    process.env.NEXT_PUBLIC_COORDINATOR_URL ||
    DEFAULT_COORDINATOR_URL;

  try {
    const url = new URL(configured);
    if (url.protocol !== "http:" && url.protocol !== "https:") {
      return Response.json({ error: { message: "coordinator URL must use http or https" } }, { status: 400 });
    }
    if (!isAllowedCoordinator(url)) {
      return Response.json(
        {
          error: {
            message:
              "coordinator URL is not allowed; set ADMIN_CONSOLE_ALLOWED_COORDINATORS to allow additional origins",
          },
        },
        { status: 400 },
      );
    }
    url.pathname = url.pathname.replace(/\/+$/, "");
    url.search = "";
    url.hash = "";
    return url.toString().replace(/\/+$/, "");
  } catch {
    return Response.json({ error: { message: "invalid coordinator URL" } }, { status: 400 });
  }
}

async function proxyAdmin(request: NextRequest, context: RouteContext): Promise<Response> {
  const base = coordinatorBase(request);
  if (base instanceof Response) {
    return base;
  }

  const params = await context.params;
  const segments = params.path ?? [];
  const upstream = new URL(`${base}/v1/admin/${segments.map(encodeURIComponent).join("/")}`);
  upstream.search = request.nextUrl.search;

  const headers = new Headers();
  headers.set("Accept", request.headers.get("Accept") || "application/json");
  headers.set("Cache-Control", "no-store");

  const token = request.headers.get("x-admin-token");
  if (token) {
    headers.set("Authorization", `Bearer ${token}`);
  }

  const init: RequestInit = {
    method: request.method,
    headers,
    cache: "no-store",
  };

  if (request.method !== "GET") {
    const contentType = request.headers.get("Content-Type");
    if (contentType) {
      headers.set("Content-Type", contentType);
    }
    init.body = await request.text();
  }

  const response = await fetch(upstream, init);
  const contentType = response.headers.get("Content-Type") || "application/json";
  const responseHeaders = new Headers({
    "Cache-Control": "no-store",
    "Content-Type": contentType,
  });

  if (contentType.includes("text/plain")) {
    return new Response(await response.text(), {
      status: response.status,
      headers: responseHeaders,
    });
  }

  return new Response(await response.text(), {
    status: response.status,
    headers: responseHeaders,
  });
}

export async function GET(request: NextRequest, context: RouteContext): Promise<Response> {
  return proxyAdmin(request, context);
}

export async function POST(request: NextRequest, context: RouteContext): Promise<Response> {
  return proxyAdmin(request, context);
}

export async function PUT(request: NextRequest, context: RouteContext): Promise<Response> {
  return proxyAdmin(request, context);
}

export async function DELETE(request: NextRequest, context: RouteContext): Promise<Response> {
  return proxyAdmin(request, context);
}
