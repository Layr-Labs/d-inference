// Text display helpers. Pure, no React.

/** Last path segment of a model id (org/name -> name). */
export function shortModelName(model: string): string {
  if (!model) return model;
  return model.split("/").pop() || model;
}
