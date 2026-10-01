import express from "express";
import type { ErrorRequestHandler } from "express";
import expressPackage from "express/package.json" with { type: "json" };
import { db, getUser, insertPost, isForeignKeyError, listPosts, parseId, parseLimit, parsePostBody, sqliteVersion } from "./db.ts";

const app = express();
app.disable("x-powered-by");
app.set("etag", false);
app.set("case sensitive routing", true);
app.set("strict routing", true);
app.get("/health", (_req, res) => res.type("text/plain").send("ok"));
app.get("/meta", (_req, res) => res.json({ runtime: `node ${process.version}`, framework: `express ${expressPackage.version}`, sqlite: sqliteVersion }));
app.get("/users/:id", (req, res) => {
  const id = parseId(req.params.id);
  if (id === null) return res.status(400).json({ error: "invalid id" });
  const user = getUser(id);
  return user ? res.json(user) : res.status(404).json({ error: "not found" });
});
app.get("/users/:id/posts", (req, res) => {
  const id = parseId(req.params.id);
  if (id === null) return res.status(400).json({ error: "invalid id" });
  const limit = parseLimit(new URLSearchParams(req.url.split("?", 2)[1]).get("limit"));
  if (limit === null) return res.status(400).json({ error: "invalid limit" });
  return res.json(listPosts(id, limit));
});
app.post("/posts", express.json({ limit: "64kb", strict: false, type: () => true, inflate: false }), (req, res) => {
  const body = parsePostBody(req.body);
  if (!body) return res.status(400).json({ error: "invalid body" });
  return res.status(201).json(insertPost(body.userId, body.title, body.body));
});
app.use((_req, res) => res.sendStatus(404));
const handleError: ErrorRequestHandler = (error: unknown, _req, res, _next) => {
  if (error instanceof URIError) {
    res.status(400).json({ error: "invalid id" });
    return;
  }
  if (typeof error === "object" && error !== null && "type" in error) {
    if (error.type === "entity.too.large") {
      res.sendStatus(413);
      return;
    }
    if (typeof error.type === "string") {
      res.status(400).json({ error: "invalid body" });
      return;
    }
  }
  if (isForeignKeyError(error)) res.status(404).json({ error: "user not found" });
  else res.status(500).json({ error: "internal" });
};
app.use(handleError);

const server = app.listen(Number(process.env.PORT ?? 3000), "127.0.0.1");
function shutdown() {
  server.close(() => {
    db.close();
    process.exit(0);
  });
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
process.on("disconnect", shutdown);
