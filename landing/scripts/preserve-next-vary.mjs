// Next.js 16.2.6 drops proxy Vary tokens in its page templates.
// Equivalent to https://github.com/vercel/next.js/pull/91039 (not yet merged).
// Remove only when a Next upgrade passes tests/markdown.test.mjs without it.
import { readFileSync, writeFileSync } from "node:fs";

const nextRoot = new URL("../node_modules/next/", import.meta.url);
const { version } = JSON.parse(readFileSync(new URL("package.json", nextRoot), "utf8"));
if (version !== "16.2.6") throw new Error(`Review the Vary patch for Next ${version} before upgrading.`);

const pageBefore = String.raw`        res.setHeader('Vary', varyHeader);
`;
const pageAfter = String.raw`        const existingVary = res.getHeader('Vary');
        const existingValues = typeof existingVary === 'string' ? existingVary.split(',') : Array.isArray(existingVary) ? existingVary.flatMap((value)=>String(value).split(',')) : [];
        const seenVary = new Set();
        const mergedVary = [];
        for (const value of [...existingValues, ...varyHeader.split(',')]){
            const token = value.trim();
            const lower = token.toLowerCase();
            if (token && !seenVary.has(lower)) {
                seenVary.add(lower);
                mergedVary.push(token);
            }
        }
        res.setHeader('Vary', mergedVary.join(', '));
`;

const edgeBefore = String.raw`        // Add existing headers
        for (const [key, value] of Object.entries({
            ...baseRes.getHeaders(),
            ...metadata.headers
        })){
            if (value !== undefined) {
                if (Array.isArray(value)) {
                    // Handle multiple header values
                    for (const v of value){
                        headers.append(key, String(v));
                    }
`;
const edgeAfter = String.raw`        // Merge Vary from both sources without shadowing proxy or RSC tokens.
        for (const source of [baseRes.getHeaders(), metadata.headers]){
            if (!source) continue;
            for (const [key, value] of Object.entries(source)){
                if (value === undefined) continue;
                if (key.toLowerCase() === 'vary') {
                    const existing = headers.get('Vary') || '';
                    const seen = new Set(existing.split(',').map((item)=>item.trim().toLowerCase()));
                    const additions = [];
                    for (const entry of Array.isArray(value) ? value : [value]){
                        for (const item of String(entry).split(',')){
                            const token = item.trim();
                            if (token && !seen.has(token.toLowerCase())) {
                                seen.add(token.toLowerCase());
                                additions.push(token);
                            }
                        }
                    }
                    if (additions.length) headers.set('Vary', [existing, ...additions].filter(Boolean).join(', '));
                } else if (Array.isArray(value)) {
                    for (const item of value) headers.append(key, String(item));
`;

for (const format of ["build", "esm/build"]) {
  for (const [template, before, after] of [
    ["app-page.js", pageBefore, pageAfter],
    ["edge-ssr-app.js", edgeBefore, edgeAfter],
  ]) {
    const path = new URL(`dist/${format}/templates/${template}`, nextRoot);
    const source = readFileSync(path, "utf8");
    if (source.includes(after)) continue;
    if (source.split(before).length !== 2) throw new Error(`Next Vary patch does not match ${path.pathname}`);
    writeFileSync(path, source.replace(before, after));
  }
}
console.log("Preserved proxy Vary headers in Next.js page templates.");
