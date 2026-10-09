import "@testing-library/jest-dom/vitest";

let testStorage: Record<string, string> = {};

const localStorageMock = {
  getItem: (key: string) => testStorage[key] ?? null,
  setItem: (key: string, value: string) => {
    testStorage[key] = String(value);
  },
  removeItem: (key: string) => {
    delete testStorage[key];
  },
  clear: () => {
    testStorage = {};
  },
  key: (index: number) => Object.keys(testStorage)[index] ?? null,
  get length() {
    return Object.keys(testStorage).length;
  },
} as Storage;

Object.defineProperty(window, "localStorage", {
  value: localStorageMock,
  configurable: true,
});
Object.defineProperty(globalThis, "localStorage", {
  value: localStorageMock,
  configurable: true,
});
