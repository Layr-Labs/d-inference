import { STORAGE_KEYS } from "../storage-keys";

export type ChatAccessMode = "session" | "api-key";
export type ChatCredentials =
  | { kind: "session"; token: string }
  | { kind: "api-key"; key: string };

/** Only a deliberately adopted key opts chat into API-key restrictions. */
export function selectedChatKey(): string | null {
  if (typeof window === "undefined") return null;
  if (!localStorage.getItem(STORAGE_KEYS.consoleKeyId)) return null;
  return localStorage.getItem(STORAGE_KEYS.apiKey);
}

/** Never combine credentials or implicitly read a saved key in session mode. */
export function chatAuthHeaders(auth: ChatCredentials): Record<string, string> {
  const secret = auth.kind === "session" ? auth.token : auth.key;
  if (!secret.trim()) throw new Error("Authentication required.");
  return auth.kind === "session"
    ? { Authorization: `Bearer ${secret}` }
    : { "x-api-key": secret };
}

export async function acquireChatCredentials(
  mode: ChatAccessMode,
  getAccessToken: () => Promise<string | null>,
): Promise<ChatCredentials> {
  if (mode === "api-key") {
    const key = selectedChatKey();
    if (!key?.trim()) throw new Error("Select an API key in the API Console, or choose login-session access.");
    return { kind: "api-key", key };
  }
  const token = await getAccessToken().catch(() => null);
  if (!token?.trim()) throw new Error("Session expired. Please sign in again.");
  return { kind: "session", token };
}
