import { NextRequest, NextResponse } from "next/server";

const PASSWORD = "bullisheigen";
const COOKIE_NAME = "dginf_access";
const COOKIE_VALUE = "granted";

export function middleware(request: NextRequest) {
  // Allow the auth endpoint through
  if (request.nextUrl.pathname === "/gate") {
    return NextResponse.next();
  }

  // Allow the device linking page through (users arrive here from CLI)
  if (request.nextUrl.pathname === "/link") {
    return NextResponse.next();
  }

  // Allow API routes through (needed for internal proxying)
  if (request.nextUrl.pathname.startsWith("/api/")) {
    return NextResponse.next();
  }

  // Allow static assets
  if (
    request.nextUrl.pathname.startsWith("/_next/") ||
    request.nextUrl.pathname.startsWith("/favicon")
  ) {
    return NextResponse.next();
  }

  // Check for auth cookie
  const accessCookie = request.cookies.get(COOKIE_NAME);
  if (accessCookie?.value === COOKIE_VALUE) {
    return NextResponse.next();
  }

  // Check for password in query param (from form submission)
  const password = request.nextUrl.searchParams.get("password");
  if (password === PASSWORD) {
    const url = request.nextUrl.clone();
    url.searchParams.delete("password");
    const response = NextResponse.redirect(url);
    response.cookies.set(COOKIE_NAME, COOKIE_VALUE, {
      httpOnly: true,
      secure: true,
      sameSite: "lax",
      maxAge: 60 * 60 * 24 * 30, // 30 days
    });
    return response;
  }

  // Redirect to gate
  const gateUrl = request.nextUrl.clone();
  gateUrl.pathname = "/gate";
  gateUrl.searchParams.set("next", request.nextUrl.pathname);
  return NextResponse.redirect(gateUrl);
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
