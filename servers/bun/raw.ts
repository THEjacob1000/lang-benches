import { closeDatabase, PostNotFound, sqliteVersion } from "./db.ts";
import { ApiError, authenticate, parseCommentBody, parseId, readFeed, readPost, writeComment } from "./domain.ts";

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: Number(process.env.PORT ?? 3000),
  reusePort: true,
  development: false,
  maxRequestBodySize: 65536,
  routes: {
    "/health": { GET: () => new Response("ok", { headers: { "Content-Type": "text/plain" } }) },
    "/meta": { GET: () => Response.json({ runtime: `bun ${Bun.version}`, framework: "bun", sqlite: sqliteVersion }) },
    "/feed": {
      GET: (request) => {
        const viewer = authenticate(request);
        return Response.json(readFeed(viewer, new URL(request.url).searchParams));
      },
    },
    "/posts/:id": {
      GET: (request) => {
        authenticate(request);
        return Response.json(readPost(parseId(request.params.id)));
      },
    },
    "/posts/:id/comments": {
      POST: async (request) => {
        const viewer = authenticate(request);
        const id = parseId(request.params.id);
        let body: unknown;
        try { body = await request.json(); }
        catch {
          throw new ApiError(400, "invalid body");
        }
        return Response.json(writeComment(id, parseCommentBody(body), viewer), { status: 201 });
      },
    },
  },
  fetch: () => new Response(null, { status: 404 }),
  error(error) {
    if (error instanceof ApiError) return Response.json({ error: error.message }, { status: error.status });
    if (error instanceof PostNotFound) return Response.json({ error: "not found" }, { status: 404 });
    return Response.json({ error: "internal" }, { status: 500 });
  },
});

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, () => { server.stop(true); closeDatabase(); process.exit(0); });
}
