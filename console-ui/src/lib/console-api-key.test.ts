// @vitest-environment jsdom
import { describe, it, expect, beforeEach } from "vitest";
import { clearConsoleApiKey, writeUntrackedConsoleApiKey } from "./console-api-key";
import { STORAGE_KEYS } from "./storage-keys";

beforeEach(() => {
  localStorage.clear();
});

describe("clearConsoleApiKey", () => {
  it("drops the secret, legacy secret, and leftover console key id", () => {
    localStorage.setItem(STORAGE_KEYS.apiKey, "sk-db-current");
    localStorage.setItem(STORAGE_KEYS.legacyApiKey, "sk-db-legacy");
    localStorage.setItem(STORAGE_KEYS.consoleKeyId, "key_stale");

    clearConsoleApiKey();

    expect(localStorage.getItem(STORAGE_KEYS.apiKey)).toBeNull();
    expect(localStorage.getItem(STORAGE_KEYS.legacyApiKey)).toBeNull();
    expect(localStorage.getItem(STORAGE_KEYS.consoleKeyId)).toBeNull();
  });
});

describe("writeUntrackedConsoleApiKey", () => {
  it("stores the mint and drops a leftover tracked id", () => {
    localStorage.setItem(STORAGE_KEYS.consoleKeyId, "key_from_previous_session");

    writeUntrackedConsoleApiKey("sk-db-untitled");

    expect(localStorage.getItem(STORAGE_KEYS.apiKey)).toBe("sk-db-untitled");
    expect(localStorage.getItem(STORAGE_KEYS.consoleKeyId)).toBeNull();
  });
});
