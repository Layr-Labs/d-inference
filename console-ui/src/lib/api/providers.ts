import { apiError } from "../http/proxy-client";

// Remove an offline/retired machine from the provider portal. The `serial` is
// the machine's stable identity token — pass serial_number when present, else
// the provider id. Ownership + the online-machine guard are enforced by the
// coordinator (403 cross-account, 409 if still online).
export async function deleteProvider(token: string, serial: string): Promise<void> {
  const res = await fetch(`/api/me/providers/${encodeURIComponent(serial)}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!res.ok) throw await apiError(res, "Failed to remove machine");
}
