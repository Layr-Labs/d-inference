// Shared formatting primitives. Import from "@/lib/format" (or a specific
// submodule). Feature-local format.ts files re-export from here so there is
// exactly one implementation of each formatter (proposal F5).

export * from "./currency";
export * from "./number";
export * from "./time";
export * from "./text";
