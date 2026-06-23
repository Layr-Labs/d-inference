// Text / identity display helpers. Pure, no React.

/** Mask a hardware serial, keeping the first 4 and last 2 chars. */
export function maskSerial(serial?: string): string {
  if (!serial) return "";
  if (serial.length <= 6) return serial;
  return serial.slice(0, 4) + "•".repeat(Math.min(6, serial.length - 6)) + serial.slice(-2);
}

/** Last path segment of a model id (org/name -> name). */
export function shortModelName(model: string): string {
  if (!model) return model;
  return model.split("/").pop() || model;
}
