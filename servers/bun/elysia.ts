import { Elysia, t, ValidationError, ParseError, NotFound } from "elysia";
import { version } from "elysia/package.json";
import { closeDatabase, PostNotFound, sqliteVersion } from "./db.ts";
import { ApiError, authenticate, parseId, readFeed, readPost, writeComment } from "./domain.ts";

const api = new Elysia()
  .derive(({ request }) => ({ viewer: authenticate(request) }))
  .get("/feed", ({ request, viewer }) => readFeed(viewer, new URL(request.url).searchParams))
  .get("/posts/:id", ({ params }) => readPost(parseId(params.id)))
  .post("/posts/:id/comments", {
    parse: "json",
    body: t.Object({ body: t.String({ minLength: 1, maxLength: 2000 }) }),
  }, ({ params, body, viewer, set }) => {
    const comment = writeComment(parseId(params.id), body.body, viewer);
    set.status = 201;
    return comment;
  });

const app = new Elysia({ serve: { development: false, maxRequestBodySize: 65536 } })
  .error(({ error }) => {
    if (error instanceof ApiError) return Response.json({ error: error.message }, { status: error.status });
    if (error instanceof PostNotFound) return Response.json({ error: "not found" }, { status: 404 });
    if (error instanceof ValidationError || error instanceof ParseError) return Response.json({ error: "invalid body" }, { status: 400 });
    if (error instanceof NotFound) return new Response(null, { status: 404 });
    return Response.json({ error: "internal" }, { status: 500 });
  })
  .get("/health", () => new Response("ok", { headers: { "Content-Type": "text/plain" } }))
  .get("/meta", () => ({ runtime: `bun ${Bun.version}`, framework: `elysia ${version}`, sqlite: sqliteVersion }))
  .use(api)
  .listen({ hostname: "127.0.0.1", port: Number(process.env.PORT ?? 3000), reusePort: true });

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, async () => { await app.stop(true); closeDatabase(); process.exit(0); });
}
