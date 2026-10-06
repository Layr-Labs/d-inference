function clean(value: unknown, max: number) {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}

export async function POST(request: Request) {
  try {
    const contentLength = Number(request.headers.get("content-length") ?? 0);
    if (contentLength > 50_000) {
      return Response.json({ error: "The submission is too large." }, { status: 413 });
    }

    const payload = (await request.json()) as Record<string, unknown>;
    if (clean(payload.company, 200)) {
      return Response.json({ ok: true }, { status: 201 });
    }

    const name = clean(payload.name, 80);
    const city = clean(payload.city, 80);
    const providerId = clean(payload.providerId, 32);
    const contact = clean(payload.contact, 140);
    const story = clean(payload.story, 4_000);

    if (!name || !city || !contact || story.length < 30 || !/^[A-Za-z0-9-]{4,32}$/.test(providerId)) {
      return Response.json({ error: "Please complete every field with a valid provider ID and story." }, { status: 400 });
    }

    const webhookUrl = process.env.DARKBLOOM_STORY_WEBHOOK_URL;
    if (!webhookUrl || !webhookUrl.startsWith("https://")) {
      return Response.json(
        { error: "Story delivery is not configured." },
        { status: 503, headers: { "retry-after": "3600" } },
      );
    }

    const token = process.env.DARKBLOOM_STORY_WEBHOOK_TOKEN;
    const response = await fetch(webhookUrl, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify({
        id: crypto.randomUUID(),
        name,
        city,
        providerId,
        contact,
        story,
        submittedAt: new Date().toISOString(),
        source: "darkbloom.dev",
      }),
      cache: "no-store",
    });
    if (!response.ok) throw new Error(`Story webhook returned ${response.status}`);

    return Response.json({ ok: true }, { status: 201 });
  } catch {
    return Response.json({ error: "The story could not be saved." }, { status: 500 });
  }
}
