import type { MetadataRoute } from "next";
import { siteOrigin } from "../content/public-site";

export default function sitemap(): MetadataRoute.Sitemap {
  // The legal source publishes this date. For other pages, request/build time
  // is not evidence that the public content changed; omit an unknown date.
  return ["/", "/about", "/developers", "/pricing", "/contact", "/privacy", "/terms"].map((path) => ({
    url: new URL(path, siteOrigin).href,
    ...(["/privacy", "/terms"].includes(path) ? { lastModified: "2026-08-28" } : {}),
  }));
}
