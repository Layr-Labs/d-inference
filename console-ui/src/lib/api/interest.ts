export interface InterestHardware {
  mac_type: string;
  chip: string;
  ram_gb: number;
}

export interface SmallModelsInterestRecord extends InterestHardware {
  created_at: string;
  updated_at: string;
}

const path = "/api/interest/small-models";

async function request(
  getToken: () => Promise<string | null>,
  signal: AbortSignal,
  hardware?: InterestHardware,
) {
  const token = await getToken();
  signal.throwIfAborted();
  if (!token) throw new Error("Sign in again to register your interest.");
  return fetch(path, {
    method: hardware ? "POST" : "GET",
    headers: {
      Authorization: `Bearer ${token}`,
      ...(hardware ? { "Content-Type": "application/json" } : {}),
    },
    ...(hardware ? { body: JSON.stringify(hardware) } : {}),
    cache: "no-store",
    signal,
  });
}

export async function registerSmallModelsInterest(
  getToken: () => Promise<string | null>, hardware: InterestHardware, signal: AbortSignal,
): Promise<void> {
  const response = await request(getToken, signal, hardware);
  if (response.status === 204) return;
  if (response.status === 422) throw new Error("Your account needs an email address before we can register your interest.");
  if (response.status === 401) throw new Error("Sign in again to register your interest.");
  throw new Error("We couldn't save your interest. Please try again.");
}

export async function readSmallModelsInterest(
  getToken: () => Promise<string | null>, signal: AbortSignal,
): Promise<SmallModelsInterestRecord | null> {
  const response = await request(getToken, signal);
  if (response.status === 404) return null;
  if (!response.ok) throw new Error("We couldn't check your registration. Please try again.");
  return response.json();
}
