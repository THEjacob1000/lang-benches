import { Elysia, t, ValidationError, ParseError, NotFound } from "elysia";
import { version } from "elysia/package.json";
import { getUser, listPosts, insertPost, sqliteVersion, parseId, parseLimit, isForeignKeyError } from "./db.ts";

const app = new Elysia({ serve: { development: false, maxRequestBodySize: 65536 } })
  .error(({ error }) => {
    if (error instanceof ValidationError || error instanceof ParseError) {
      return Response.json({ error: "invalid body" }, { status: 400 });
    }
    if (error instanceof NotFound) return new Response(null, { status: 404 });
    return Response.json({ error: "internal" }, { status: 500 });
  })
  .get("/health", () => new Response("ok", { headers: { "Content-Type": "text/plain" } }))
  .get("/meta", () => ({ runtime: `bun ${Bun.version}`, framework: `elysia ${version}`, sqlite: sqliteVersion }))
  .get("/users/:id", ({ params }) => {
    const id = parseId(params.id);
    if (id === null) return Response.json({ error: "invalid id" }, { status: 400 });
    const user = getUser(id);
    return user ?? Response.json({ error: "not found" }, { status: 404 });
  })
  .get("/users/:id/posts", ({ params, request }) => {
    const id = parseId(params.id);
    if (id === null) return Response.json({ error: "invalid id" }, { status: 400 });
    const limit = parseLimit(new URL(request.url).searchParams.get("limit"));
    if (limit === null) return Response.json({ error: "invalid limit" }, { status: 400 });
    return listPosts(id, limit);
  })
  .post("/posts", {
    parse: "json",
    body: t.Object({
      // Integer schemas coerce numeric strings in Elysia 2; JSON userId must stay numeric.
      userId: t.Number({ minimum: 1, maximum: Number.MAX_SAFE_INTEGER, multipleOf: 1 }),
      title: t.String({ minLength: 1, maxLength: 200 }),
      body: t.String({ minLength: 1, maxLength: 10000 }),
    }),
  }, ({ body, set }) => {
    try {
      const post = insertPost(body.userId, body.title, body.body);
      set.status = 201;
      return post;
    } catch (error) {
      if (isForeignKeyError(error)) return Response.json({ error: "user not found" }, { status: 404 });
      throw error;
    }
  })
  .listen({ hostname: "127.0.0.1", port: Number(process.env.PORT ?? 3000), reusePort: true });

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, async () => { await app.stop(true); process.exit(0); });
}
