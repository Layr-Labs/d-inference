// Structured API errors for the /api/* proxy routes.
//
// The coordinator returns OpenAI-style error envelopes:
//   { "error": { "type": "<code>", "message": "...", "code": "<code>" } }
// but the Next.js proxy routes re-wrap non-OK bodies as { error: "<raw text>" }
// where <raw text> is the JSON-encoded coordinator body. parseApiErrorBody
// unwraps both shapes so callers get the machine-readable code (used by the
// payout UI to map backend failures to friendly copy) plus the raw message.

export class ApiError extends Error {
  /** Machine-readable error code, e.g. "stripe_account_gone". "" if unknown. */
  readonly code: string;
  /** HTTP status of the failed response. 0 if unknown. */
  readonly status: number;

  constructor(message: string, code = "", status = 0) {
    super(message);
    this.name = "ApiError";
    this.code = code;
    this.status = status;
  }
}

interface ParsedApiError {
  code: string;
  message: string;
}

// parseErrorDetail reads { message, type, code } off a coordinator error
// detail object (code mirrors type by default - see errorResponse in
// coordinator/api/httputil.go).
function parseErrorDetail(err: object): ParsedApiError | null {
  const e = err as { message?: unknown; type?: unknown; code?: unknown };
  const message = typeof e.message === "string" ? e.message : "";
  let code = "";
  if (typeof e.code === "string" && e.code !== "") {
    code = e.code;
  } else if (typeof e.type === "string") {
    code = e.type;
  }
  if (message || code) return { code, message: message || code };
  return null;
}

// parseErrorString handles the proxy routes' { error: "<raw text>" } wrapping:
// if the text is itself a JSON envelope, unwrap it; otherwise treat it as a
// plain message.
function parseErrorString(text: string): ParsedApiError | null {
  const trimmed = text.trim();
  if (!trimmed) return null;
  try {
    const inner = parseApiErrorBody(JSON.parse(trimmed));
    if (inner) return inner;
  } catch {
    // Not JSON - treat as a plain message.
  }
  return { code: "", message: trimmed };
}

// parseApiErrorBody extracts { code, message } from a decoded error response
// body. Handles the direct coordinator envelope, the proxy's string-wrapped
// envelope, and plain-string errors. Returns null when nothing usable exists.
export function parseApiErrorBody(body: unknown): ParsedApiError | null {
  if (!body || typeof body !== "object") return null;
  const err = (body as { error?: unknown }).error;
  if (typeof err === "string") return parseErrorString(err);
  if (err && typeof err === "object") return parseErrorDetail(err);
  return null;
}

// apiErrorFromBody builds an ApiError from a decoded (possibly empty) error
// response body, falling back to the caller-supplied generic message.
export function apiErrorFromBody(body: unknown, status: number, fallback: string): ApiError {
  const parsed = parseApiErrorBody(body);
  return new ApiError(parsed?.message || fallback, parsed?.code ?? "", status);
}
