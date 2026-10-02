import { createHmac, timingSafeEqual } from "node:crypto";

export type Viewer = { id: number; name: string };
export type PostRow = { id: number; title: string; body: string; commentCount: number; createdAt: number; authorId: number; authorName: string };
export type CommentRow = { id: number; body: string; createdAt: number; authorId: number; authorName: string };
export type Cursor = { createdAt: number; postId: number };

const secret = process.env.JWT_SECRET;
if (!secret) throw new Error("JWT_SECRET is required");
const key = Buffer.from(secret, "utf8");

function decodeBase64url(value: string): Buffer | null {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) return null;
  const bytes = Buffer.from(value, "base64url");
  return bytes.toString("base64url") === value ? bytes : null;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function verifyAuthorization(authorization: string | undefined): Viewer | null {
  if (!authorization?.startsWith("Bearer ")) return null;
  const segments = authorization.slice(7).split(".");
  if (segments.length !== 3) return null;
  const [headerSegment, payloadSegment, signatureSegment] = segments;
  const headerBytes = decodeBase64url(headerSegment);
  const payloadBytes = decodeBase64url(payloadSegment);
  const signature = decodeBase64url(signatureSegment);
  if (!headerBytes || !payloadBytes || !signature) return null;
  try {
    const header: unknown = JSON.parse(headerBytes.toString("utf8"));
    if (!isObject(header) || header.alg !== "HS256") return null;
    const expected = createHmac("sha256", key).update(`${headerSegment}.${payloadSegment}`).digest();
    if (signature.length !== expected.length || !timingSafeEqual(signature, expected)) return null;
    const payload: unknown = JSON.parse(payloadBytes.toString("utf8"));
    if (!isObject(payload) || typeof payload.sub !== "number" || !Number.isSafeInteger(payload.sub) || payload.sub < 1 ||
        typeof payload.name !== "string" || payload.iss !== "gbb" || typeof payload.exp !== "number" ||
        !Number.isInteger(payload.exp) || payload.exp * 1000 <= Date.now()) return null;
    return { id: payload.sub, name: payload.name };
  } catch {
    return null;
  }
}

export function parseId(value: string): number | null {
  if (!/^[0-9]+$/.test(value)) return null;
  const id = Number(value);
  return Number.isSafeInteger(id) && id > 0 ? id : null;
}

export function parseLimit(value: string | null): number | null {
  if (value === null) return 20;
  const limit = parseId(value);
  return limit !== null && limit <= 50 ? limit : null;
}

export function parseCursor(value: string | null): Cursor | null {
  if (value === null) return { createdAt: Number.MAX_SAFE_INTEGER, postId: Number.MAX_SAFE_INTEGER };
  const bytes = decodeBase64url(value);
  if (!bytes) return null;
  const match = /^([0-9]+):([0-9]+)$/.exec(bytes.toString("utf8"));
  if (!match) return null;
  const createdAt = parseId(match[1]);
  const postId = parseId(match[2]);
  return createdAt !== null && postId !== null ? { createdAt, postId } : null;
}

export function parseCommentBody(value: unknown): string | null {
  if (!isObject(value) || typeof value.body !== "string" || value.body.length < 1 || value.body.length > 2000) return null;
  return value.body;
}

export function deriveFields(body: string) {
  let wordCount = 0;
  const tags: string[] = [];
  let start = 0;
  while (start < body.length) {
    if (body[start] === " ") {
      start++;
      continue;
    }
    let end = body.indexOf(" ", start);
    if (end === -1) end = body.length;
    wordCount++;
    if (tags.length < 5 && body[start] === "#") {
      const word = body.slice(start + 1, end);
      if (/^[a-z0-9_]+$/.test(word) && !tags.includes(word)) tags.push(word);
    }
    start = end + 1;
  }
  return { wordCount, readingMinutes: Math.max(1, Math.ceil(wordCount / 200)), tags };
}

function excerpt(body: string): string {
  if (body.length <= 200) return body;
  const prefix = body.slice(0, 200);
  const space = prefix.lastIndexOf(" ");
  return `${space === -1 ? prefix : prefix.slice(0, space)}...`;
}

export function shapeFeedPost(row: PostRow) {
  return {
    id: row.id, title: row.title, excerpt: excerpt(row.body), ...deriveFields(row.body),
    commentCount: row.commentCount, createdAt: row.createdAt, author: { id: row.authorId, name: row.authorName },
  };
}

export function shapePost(row: PostRow) {
  return {
    id: row.id, title: row.title, body: row.body, ...deriveFields(row.body),
    commentCount: row.commentCount, createdAt: row.createdAt, author: { id: row.authorId, name: row.authorName },
  };
}

export function shapeComment(row: CommentRow) {
  return { id: row.id, body: row.body, createdAt: row.createdAt, author: { id: row.authorId, name: row.authorName } };
}

export function nextCursor(rows: PostRow[], limit: number): string | null {
  if (rows.length !== limit) return null;
  const last = rows[rows.length - 1];
  return Buffer.from(`${last.createdAt}:${last.id}`).toString("base64url");
}
