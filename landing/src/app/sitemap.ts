import type { MetadataRoute } from "next";
import { publicPagePaths, siteOrigin } from "../content/public-site";

export default function sitemap(): MetadataRoute.Sitemap {
  // The legal source publishes this date. For other pages, request/build time
  // is not evidence that the public content changed; omit an unknown date.
  return publicPagePaths.map((path) => ({
    url: new URL(path, siteOrigin).href,
    ...(["/privacy", "/terms"].includes(path) ? { lastModified: "2026-08-28" } : {}),
  }));
}
