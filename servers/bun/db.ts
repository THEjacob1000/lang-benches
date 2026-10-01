import { Database, SQLiteError } from "bun:sqlite";
import { existsSync } from "node:fs";

const path = process.env.DB_PATH;
if (!path || !existsSync(path)) throw new Error("DB_PATH must name an existing database");
const db = new Database(path, { strict: true, create: false, readwrite: true });
db.exec(`
  PRAGMA busy_timeout = 5000;
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = NORMAL;
  PRAGMA foreign_keys = ON;
  PRAGMA cache_size = -16000;
  PRAGMA temp_store = MEMORY;
`);

type User = { id: number; name: string; email: string; createdAt: number };
export type PostBody = { userId: number; title: string; body: string };
type Post = { id: number; userId: number; title: string; body: string; createdAt: number };
const user = db.query<User, [number]>("SELECT id, name, email, created_at AS createdAt FROM users WHERE id = ?");
const posts = db.query<Post, [number, number]>("SELECT id, user_id AS userId, title, body, created_at AS createdAt FROM posts WHERE user_id = ? ORDER BY id DESC LIMIT ?");
const insert = db.query<{ id: number }, [number, string, string, number]>("INSERT INTO posts (user_id, title, body, created_at) VALUES (?, ?, ?, ?) RETURNING id");
export const sqliteVersion = db.query<{ version: string }, []>("SELECT sqlite_version() AS version").get()!.version;

export function getUser(id: number): User | null {
  return user.get(id);
}

export function listPosts(userId: number, limit: number): Post[] {
  return posts.all(userId, limit);
}

export function insertPost(userId: number, title: string, body: string): Post {
  const createdAt = Date.now();
  const { id } = insert.get(userId, title, body, createdAt)!;
  return { id, userId, title, body, createdAt };
}

export function parseId(value: string): number | null {
  if (!/^[0-9]+$/.test(value)) return null;
  const id = Number(value);
  return Number.isSafeInteger(id) && id > 0 ? id : null;
}

export function parseLimit(value: string | null): number | null {
  if (value === null) return 20;
  if (!/^[0-9]+$/.test(value)) return null;
  const limit = Number(value);
  return Number.isInteger(limit) && limit >= 1 && limit <= 100 ? limit : null;
}

export function parsePostBody(value: unknown): PostBody | null {
  if (typeof value !== "object" || value === null) return null;
  if (!("userId" in value && "title" in value && "body" in value)) return null;
  const { userId, title, body } = value;
  if (typeof userId !== "number" || !Number.isSafeInteger(userId) || userId <= 0) return null;
  if (typeof title !== "string" || title.length < 1 || title.length > 200) return null;
  if (typeof body !== "string" || body.length < 1 || body.length > 10000) return null;
  return { userId, title, body };
}

export function isForeignKeyError(error: unknown): boolean {
  return error instanceof SQLiteError && error.code === "SQLITE_CONSTRAINT_FOREIGNKEY";
}
