import { NextResponse, type NextRequest } from "next/server";
import { checkBasicAuth } from "@/lib/auth";

// Gate every route behind HTTP Basic Auth. This is the single auth surface for
// the whole internal tool — there are no public routes.
export function middleware(req: NextRequest) {
  if (checkBasicAuth(req.headers.get("authorization"))) {
    return NextResponse.next();
  }
  return new NextResponse("Authentication required", {
    status: 401,
    headers: { "WWW-Authenticate": 'Basic realm="admin-ui", charset="UTF-8"' },
  });
}

export const config = {
  // Apply to everything except Next internals and static assets.
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
