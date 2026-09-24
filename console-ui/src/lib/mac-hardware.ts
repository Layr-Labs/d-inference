export type MacKind = "studio" | "mini" | "macbook" | "desktop" | "unknown";

// hw.model uses opaque identifiers on newer Macs. Match only known models;
// a chip name cannot distinguish a laptop from a desktop.
// Apple model lists (checked September 2026):
// https://support.apple.com/en-us/102231 (Studio)
// https://support.apple.com/en-us/102852 (mini)
// https://support.apple.com/en-us/108052 (MacBook Pro)
// https://support.apple.com/en-us/102869 (MacBook Air)
const STUDIO = new Set(["Mac13,1", "Mac13,2", "Mac14,13", "Mac14,14", "Mac15,14", "Mac16,9"].map((id) => id.toLowerCase()));
const MINI = new Set(["Mac14,3", "Mac14,12", "Mac16,10", "Mac16,11"].map((id) => id.toLowerCase()));
const PRO = new Set([
  "Mac14,5", "Mac14,6", "Mac14,7", "Mac14,9", "Mac14,10",
  "Mac15,3", "Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11",
  "Mac16,1", "Mac16,5", "Mac16,6", "Mac16,7", "Mac16,8",
  "Mac17,2", "Mac17,6", "Mac17,7", "Mac17,8", "Mac17,9",
].map((id) => id.toLowerCase()));
const AIR = new Set([
  "Mac14,2", "Mac14,15", "Mac15,12", "Mac15,13", "Mac16,12", "Mac16,13", "Mac17,3", "Mac17,4",
].map((id) => id.toLowerCase()));

export function macIdentity(model?: string): { kind: MacKind; name: string } {
  const raw = model?.trim() || "";
  const key = raw.toLowerCase().replace(/\s+/g, "");
  if (key.startsWith("macstudio") || STUDIO.has(key)) return { kind: "studio", name: "Mac Studio" };
  if (key.startsWith("macmini") || MINI.has(key)) return { kind: "mini", name: "Mac mini" };
  if (key.startsWith("macbookpro") || PRO.has(key)) return { kind: "macbook", name: "MacBook Pro" };
  if (key.startsWith("macbookair") || AIR.has(key)) return { kind: "macbook", name: "MacBook Air" };
  if (key.startsWith("macbook")) return { kind: "macbook", name: "MacBook" };
  if (key.startsWith("imac")) return { kind: "desktop", name: "iMac" };
  return { kind: "unknown", name: raw || "Mac" };
}
