import { NextRequest, NextResponse } from "next/server";
import { publicPagePaths, siteOrigin } from "./content/public-site";
import { markdownDocuments, agentIndex, authenticationMarkdown, missingDocumentMarkdown } from "./content/agent-resources";

// Resolve each representation against its most specific matching media range.
// A wildcard must never resurrect an explicitly excluded representation.
function mediaPreference(accept: string, subtype: string) {
  let result = { quality: 0, specificity: -1, position: Infinity };
  accept.split(",").forEach((entry, position) => {
    const [rawType, ...parameters] = entry.trim().toLowerCase().split(";");
    const specificity = rawType === `text/${subtype}` ? 2
      : rawType === "text/*" ? 1 : rawType === "*/*" ? 0 : -1;
    if (specificity < 0) return;
    let quality = 1;
    for (const parameter of parameters) {
      const [key, value] = parameter.trim().split("=");
      if (key === "q") {
        quality = /^(?:0(?:\.\d{0,3})?|1(?:\.0{0,3})?)$/.test(value ?? "") ? Number(value) : 0;
      } else if (key !== "charset" || value?.replaceAll('"', "") !== "utf-8") {
        return;
      }
    }
    if (specificity > result.specificity) result = { quality, specificity, position };
  });
  return result;
}

function prefersMarkdown(accept: string) {
  const markdown = mediaPreference(accept, "markdown");
  const html = mediaPreference(accept, "html");
  return markdown.specificity === 2 && markdown.quality > 0 && (
    markdown.quality > html.quality ||
    (markdown.quality === html.quality && (
      markdown.specificity > html.specificity || markdown.position < html.position
    ))
  );
}

function discoveryLinks(documentPath = "/") {
  const alternate = documentPath === "/" ? "/index.md" : `${documentPath}.md`;
  return [
    `<${siteOrigin}${alternate}>; rel="alternate"; type="text/markdown"`,
    `<${siteOrigin}/llms.txt>; rel="describedby"; type="text/plain"`,
    `<${siteOrigin}/openapi.json>; rel="service-desc"; type="application/vnd.oai.openapi+json"`,
  ].join(", ");
}

function markdownResponse(body: string, status = 200, documentPath = "/") {
  return new NextResponse(body, {
    status,
    headers: {
      "Content-Type": "text/markdown; charset=utf-8",
      Vary: "Accept",
      "Cache-Control": "no-store",
      Link: discoveryLinks(documentPath),
    },
  });
}

export async function proxy(request: NextRequest) {
  if (request.method !== "GET" && request.method !== "HEAD") return NextResponse.next();
  const path = request.nextUrl.pathname;
  const markdown = prefersMarkdown(request.headers.get("accept") ?? "");
  if (path === "/llms.txt") {
    return new NextResponse(agentIndex(), {
      headers: { "Content-Type": "text/plain; charset=utf-8", Link: discoveryLinks() },
    });
  }
  if (path === "/auth.md") return markdownResponse(authenticationMarkdown());
  const documentPath = path === "/index.md" ? "/" : path.endsWith(".md") ? path.slice(0, -3) : path;
  const document = markdownDocuments[documentPath];
  if (document && (path.endsWith(".md") || markdown)) return markdownResponse(await document(), 200, documentPath);

  const response = NextResponse.next();
  if (document) {
    response.headers.append("Vary", "Accept");
    response.headers.append("Link", discoveryLinks(documentPath));
  }

  // Static files and protocol endpoints retain their own routing and errors.
  // /docs must reach its existing query-preserving redirect.
  const protectedPath = /^\/(?:api|_next|assets|fonts|images|videos|media|icons|docs)(?:\/|$)/.test(path) || path.startsWith("/.");
  const existingPage = publicPagePaths.some((publicPath) => publicPath === path);
  const isDocumentPath = !path.includes(".") || path.endsWith(".md");
  if (!protectedPath && !existingPage && isDocumentPath) {
    if (markdown) return markdownResponse(missingDocumentMarkdown, 404);
    response.headers.append("Vary", "Accept");
  }
  return response;
}

// Next removes Flight headers before calling proxy(), so exclude RSC at the
// matcher boundary where the original protocol headers are still available.
export const config = {
  matcher: [{ source: "/:path*", missing: [{ type: "header", key: "rsc", value: "1" }] }],
};
