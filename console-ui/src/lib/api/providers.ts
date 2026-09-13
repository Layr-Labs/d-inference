import { apiError } from "../http/proxy-client";

// Remove an offline/retired machine by its opaque provider session id.
// Ownership + the online-machine guard are enforced by the coordinator.
export async function deleteProvider(token: string, providerID: string): Promise<void> {
  const res = await fetch(`/api/me/providers/${encodeURIComponent(providerID)}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!res.ok) throw await apiError(res, "Failed to remove machine");
}
