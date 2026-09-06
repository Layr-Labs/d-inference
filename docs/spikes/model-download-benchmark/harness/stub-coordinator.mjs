// Minimal stand-in for the coordinator's two catalog endpoints the Darkbloom
// downloader uses. Serves the generated benchmark catalog only.
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
const PORT = Number(process.env.PORT ?? 8799);
const catalog = readFileSync("out/catalog.json", "utf8");
createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  const send = (code, body, type = "application/json") => { res.writeHead(code, { "Content-Type": type }); res.end(body); };
  if (url.pathname === "/v1/models/catalog") return send(200, catalog);
  const m = url.pathname.match(/^\/v1\/models\/catalog\/manifest\/(.+)$/);
  if (m) { try { return send(200, readFileSync(`out/manifest-${decodeURIComponent(m[1])}.json`, "utf8")); } catch { return send(404, JSON.stringify({ error: { code: "not_found", message: "model not found" } })); } }
  if (url.pathname === "/health") return send(200, JSON.stringify({ ok: true }));
  send(404, JSON.stringify({ error: { code: "not_found", message: "no such route" } }));
}).listen(PORT, "0.0.0.0", () => console.log(`stub coordinator on :${PORT}`));
