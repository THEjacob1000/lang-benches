import { getUser, listPosts, insertPost, sqliteVersion, parseId, parseLimit, parsePostBody, isForeignKeyError } from "./db.ts";

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: Number(process.env.PORT ?? 3000),
  reusePort: true,
  development: false,
  maxRequestBodySize: 65536,
  routes: {
    "/health": { GET: () => new Response("ok", { headers: { "Content-Type": "text/plain" } }) },
    "/meta": { GET: () => Response.json({ runtime: `bun ${Bun.version}`, framework: "bun", sqlite: sqliteVersion }) },
    "/users/:id": {
      GET: (req) => {
        const id = parseId(req.params.id);
        if (id === null) return Response.json({ error: "invalid id" }, { status: 400 });
        try {
          const user = getUser(id);
          return user ? Response.json(user) : Response.json({ error: "not found" }, { status: 404 });
        } catch {
          return Response.json({ error: "internal" }, { status: 500 });
        }
      },
    },
    "/users/:id/posts": {
      GET: (req) => {
        const id = parseId(req.params.id);
        if (id === null) return Response.json({ error: "invalid id" }, { status: 400 });
        const limit = parseLimit(new URL(req.url).searchParams.get("limit"));
        if (limit === null) return Response.json({ error: "invalid limit" }, { status: 400 });
        try {
          return Response.json(listPosts(id, limit));
        } catch {
          return Response.json({ error: "internal" }, { status: 500 });
        }
      },
    },
    "/posts": {
      POST: async (req) => {
        let value: unknown;
        try {
          value = await req.json();
        } catch {
          return Response.json({ error: "invalid body" }, { status: 400 });
        }
        const post = parsePostBody(value);
        if (!post) return Response.json({ error: "invalid body" }, { status: 400 });
        try {
          return Response.json(insertPost(post.userId, post.title, post.body), { status: 201 });
        } catch (error) {
          return isForeignKeyError(error)
            ? Response.json({ error: "user not found" }, { status: 404 })
            : Response.json({ error: "internal" }, { status: 500 });
        }
      },
    },
  },
  fetch: () => new Response(null, { status: 404 }),
});

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, () => { server.stop(true); process.exit(0); });
}
