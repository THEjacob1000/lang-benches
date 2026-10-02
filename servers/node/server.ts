import express from "express";
import type { ErrorRequestHandler, RequestHandler } from "express";
import expressPackage from "express/package.json" with { type: "json" };
import { createComment, db, getFeed, getPost, PostNotFoundError, sqliteVersion } from "./db.ts";
import { nextCursor, parseCommentBody, parseCursor, parseId, parseLimit, shapeComment, shapeFeedPost, shapePost, verifyAuthorization } from "./domain.ts";
import type { Viewer } from "./domain.ts";

type ApiLocals = { viewer: Viewer; postId: number };
const authenticate: RequestHandler<Record<string, string>, unknown, unknown, unknown, ApiLocals> = (req, res, next) => {
  const viewer = verifyAuthorization(req.headers.authorization);
  if (!viewer) {
    res.status(401).json({ error: "unauthorized" });
    return;
  }
  res.locals.viewer = viewer;
  next();
};
const validatePostId: RequestHandler<Record<string, string>, unknown, unknown, unknown, ApiLocals> = (req, res, next) => {
  const id = parseId(req.params.id);
  if (id === null) {
    res.status(400).json({ error: "invalid id" });
    return;
  }
  res.locals.postId = id;
  next();
};

const app = express();
app.disable("x-powered-by");
app.set("etag", false);
app.set("case sensitive routing", true);
app.set("strict routing", true);
app.get("/health", (_req, res) => res.type("text/plain").send("ok"));
app.get("/meta", (_req, res) => res.json({ runtime: `node ${process.version}`, framework: `express ${expressPackage.version}`, sqlite: sqliteVersion }));
app.get<Record<string, string>, unknown, unknown, unknown, ApiLocals>("/feed", authenticate, (req, res) => {
  const queryStart = req.url.indexOf("?");
  const query = new URLSearchParams(queryStart === -1 ? "" : req.url.slice(queryStart + 1));
  const limit = parseLimit(query.get("limit"));
  if (limit === null) return res.status(400).json({ error: "invalid limit" });
  const cursor = parseCursor(query.get("cursor"));
  if (!cursor) return res.status(400).json({ error: "invalid cursor" });
  const rows = getFeed(res.locals.viewer.id, cursor, limit);
  return res.json({ viewer: res.locals.viewer, items: rows.map(shapeFeedPost), nextCursor: nextCursor(rows, limit) });
});
app.get<Record<string, string>, unknown, unknown, unknown, ApiLocals>("/posts/:id", authenticate, validatePostId, (_req, res) => {
  const result = getPost(res.locals.postId);
  return result ? res.json({ post: shapePost(result.post), comments: result.comments.map(shapeComment) }) : res.status(404).json({ error: "not found" });
});
app.post<Record<string, string>, unknown, unknown, unknown, ApiLocals>("/posts/:id/comments", authenticate, validatePostId,
  express.json({ limit: "64kb", strict: false, type: () => true, inflate: false }), (req, res) => {
    const body = parseCommentBody(req.body);
    if (body === null) return res.status(400).json({ error: "invalid body" });
    return res.status(201).json(createComment(res.locals.postId, body, res.locals.viewer));
  });
app.use((_req, res) => res.sendStatus(404));
const handleError: ErrorRequestHandler = (error: unknown, req, res, _next) => {
  if (error instanceof URIError) {
    const postRoute = req.method === "GET" && /^\/posts\/[^/]+$/.test(req.path);
    const commentRoute = req.method === "POST" && /^\/posts\/[^/]+\/comments$/.test(req.path);
    if (postRoute || commentRoute) res.status(400).json({ error: "invalid id" });
    else res.sendStatus(404);
  } else if (typeof error === "object" && error !== null && "type" in error && typeof error.type === "string") {
    if (error.type === "entity.too.large") res.sendStatus(413);
    else res.status(400).json({ error: "invalid body" });
  } else if (error instanceof PostNotFoundError) {
    res.status(404).json({ error: "not found" });
  } else {
    res.status(500).json({ error: "internal" });
  }
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
