// A stand-in for Google Drive's v3 REST API, enough for budget_sync's
// GoogleDriveAppData: list, create folder, multipart upload, download and
// delete in the app data folder. Smoke tests only.
export function fakeDrive(files = []) {
  const entries = new Map(
    files.map((f) => [
      f.id,
      {
        ...f,
        bytes: f.bytes ? Uint8Array.from(Buffer.from(f.bytes, "base64")) : null,
      },
    ]),
  );
  let next = 1;
  const folderMime = "application/vnd.google-apps.folder";
  const json = (body, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });

  async function fetch(url, init = {}) {
    const u = new URL(url);
    const method = init.method ?? "GET";
    const auth = new Headers(init.headers).get("authorization");
    if (auth !== "Bearer test-token") return json({ error: "auth" }, 401);
    const body = init.body ? new Uint8Array(init.body) : null;
    const id = u.pathname.match(/\/files\/([^/]+)$/)?.[1];
    if (method === "GET" && u.pathname.endsWith("/files")) {
      const q = u.searchParams.get("q") ?? "";
      const parent = q.match(/'([^']+)' in parents/)?.[1] ?? "appDataFolder";
      return json({
        files: [...entries.values()]
          .filter((e) => e.parent === parent)
          .map((e) => ({
            id: e.id,
            name: e.name,
            mimeType: e.folder ? folderMime : "application/octet-stream",
          })),
      });
    }
    if (method === "GET" && id) {
      const entry = entries.get(id);
      if (!entry) return json({ error: "missing" }, 404);
      return new Response(entry.bytes);
    }
    if (method === "DELETE" && id) {
      entries.delete(id);
      return new Response(null, { status: 204 });
    }
    if (method === "POST" && u.pathname.endsWith("/files") && !u.pathname.includes("upload")) {
      const meta = JSON.parse(new TextDecoder().decode(body));
      const newId = `f${next++}`;
      entries.set(newId, { id: newId, name: meta.name, parent: meta.parents[0], folder: true });
      return json({ id: newId });
    }
    if (method === "POST" && u.pathname.includes("/upload/")) {
      const text = Buffer.from(body).toString("latin1");
      const boundary = text.slice(2, text.indexOf("\r\n"));
      const metaStart = text.indexOf("\r\n\r\n") + 4;
      const metaEnd = text.indexOf(`\r\n--${boundary}`, metaStart);
      const meta = JSON.parse(text.slice(metaStart, metaEnd));
      const mediaStart = text.indexOf("\r\n\r\n", metaEnd) + 4;
      const mediaEnd = text.lastIndexOf(`\r\n--${boundary}--`);
      const newId = `f${next++}`;
      entries.set(newId, {
        id: newId,
        name: meta.name,
        parent: meta.parents[0],
        folder: false,
        bytes: body.slice(mediaStart, mediaEnd),
      });
      return json({ id: newId });
    }
    return json({ error: `unhandled ${method} ${u.pathname}` }, 400);
  }

  return { fetch, entries };
}
