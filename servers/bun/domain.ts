import { createHmac, timingSafeEqual } from "node:crypto";
import { getPost, insertComment, listComments, listFeed, type PostRow } from "./db.ts";

const secret = process.env.JWT_SECRET;
if (!secret) throw new Error("JWT_SECRET is required");
export type Viewer = { id: number; name: string };
export class ApiError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

function decodeSegment(value: string): Buffer | null {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) return null;
  const decoded = Buffer.from(value, "base64url");
  return decoded.toString("base64url") === value ? decoded : null;
}
function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
export function authenticate(request: Request): Viewer {
  try {
    const authorization = request.headers.get("authorization");
    if (!authorization?.startsWith("Bearer ")) throw new Error();
    const segments = authorization.slice(7).split(".");
    if (segments.length !== 3) throw new Error();
    const [headerSegment, payloadSegment, signatureSegment] = segments as [string, string, string];
    const headerBytes = decodeSegment(headerSegment);
    const payloadBytes = decodeSegment(payloadSegment);
    const signature = decodeSegment(signatureSegment);
    if (!headerBytes || !payloadBytes || !signature) throw new Error();
    const header: unknown = JSON.parse(headerBytes.toString("utf8"));
    if (!isObject(header) || header.alg !== "HS256") throw new Error();
    const expected = createHmac("sha256", secret!).update(`${headerSegment}.${payloadSegment}`).digest();
    if (signature.length !== expected.length || !timingSafeEqual(signature, expected)) throw new Error();
    const payload: unknown = JSON.parse(payloadBytes.toString("utf8"));
    if (!isObject(payload) || typeof payload.sub !== "number" || !Number.isSafeInteger(payload.sub) || payload.sub < 1 || typeof payload.name !== "string" || payload.iss !== "gbb" || typeof payload.exp !== "number" || !Number.isSafeInteger(payload.exp) || payload.exp * 1000 <= Date.now()) throw new Error();
    return { id: payload.sub, name: payload.name };
  } catch {
    throw new ApiError(401, "unauthorized");
  }
}
export function parseId(value: string): number {
  const id = Number(value);
  if (!/^[0-9]+$/.test(value) || !Number.isSafeInteger(id) || id < 1) throw new ApiError(400, "invalid id");
  return id;
}
export function parseLimit(value: string | null): number {
  if (value === null) return 20;
  const limit = Number(value);
  if (!/^[0-9]+$/.test(value) || !Number.isSafeInteger(limit) || limit < 1 || limit > 50) throw new ApiError(400, "invalid limit");
  return limit;
}
export function parseCursor(value: string | null): [number, number] {
  if (value === null) return [Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER];
  const decoded = decodeSegment(value);
  const parts = decoded?.toString("utf8").split(":");
  if (!parts || parts.length !== 2) throw new ApiError(400, "invalid cursor");
  try { return [parseId(parts[0]!), parseId(parts[1]!)]; }
  catch { throw new ApiError(400, "invalid cursor"); }
}
export function parseCommentBody(value: unknown): string {
  if (!isObject(value) || typeof value.body !== "string" || value.body.length < 1 || value.body.length > 2000) throw new ApiError(400, "invalid body");
  return value.body;
}
function derivedFields(body: string) {
  let wordCount = 0;
  const tags: string[] = [];
  for (let start = 0; start < body.length;) {
    if (body[start] === " ") { start++; continue; }
    let end = body.indexOf(" ", start);
    if (end === -1) end = body.length;
    wordCount++;
    if (tags.length < 5 && body[start] === "#") {
      const tag = body.slice(start + 1, end);
      if (/^[a-z0-9_]+$/.test(tag) && !tags.includes(tag)) tags.push(tag);
    }
    start = end + 1;
  }
  return { wordCount, readingMinutes: Math.max(1, Math.ceil(wordCount / 200)), tags };
}
function shapePost(row: PostRow, feed: boolean) {
  let excerpt = row.body;
  if (feed && excerpt.length > 200) {
    excerpt = excerpt.slice(0, 200);
    const space = excerpt.lastIndexOf(" ");
    if (space !== -1) excerpt = excerpt.slice(0, space);
    excerpt += "...";
  }
  return {
    id: row.id, title: row.title, ...(feed ? { excerpt } : { body: row.body }),
    ...derivedFields(row.body), commentCount: row.commentCount, createdAt: row.createdAt,
    author: { id: row.authorId, name: row.authorName },
  };
}
export function readFeed(viewer: Viewer, query: URLSearchParams) {
  const limit = parseLimit(query.get("limit"));
  const cursor = parseCursor(query.get("cursor"));
  const rows = listFeed(viewer.id, cursor, limit);
  const last = rows.at(-1);
  return { viewer, items: rows.map((row) => shapePost(row, true)), nextCursor: rows.length === limit && last ? Buffer.from(`${last.createdAt}:${last.id}`).toString("base64url") : null };
}
export function readPost(id: number) {
  const row = getPost(id);
  if (!row) throw new ApiError(404, "not found");
  return { post: shapePost(row, false), comments: listComments(id).map((comment) => ({ id: comment.id, body: comment.body, createdAt: comment.createdAt, author: { id: comment.authorId, name: comment.authorName } })) };
}
export function writeComment(id: number, body: string, viewer: Viewer) {
  const createdAt = Date.now();
  const commentId = insertComment(id, viewer.id, body, createdAt);
  return { id: commentId, postId: id, body, createdAt, author: viewer };
}
