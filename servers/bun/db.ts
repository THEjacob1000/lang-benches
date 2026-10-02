import { Database } from "bun:sqlite";
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

export type PostRow = {
  id: number; title: string; body: string; commentCount: number; createdAt: number;
  authorId: number; authorName: string;
};
export type CommentRow = {
  id: number; body: string; createdAt: number; authorId: number; authorName: string;
};
const feed = db.query<PostRow, [number, number, number, number]>("SELECT p.id, p.title, p.body, p.comment_count AS commentCount, p.created_at AS createdAt, u.id AS authorId, u.name AS authorName FROM feed_items f JOIN posts p ON p.id = f.post_id JOIN users u ON u.id = p.user_id WHERE f.user_id = ? AND (f.created_at, f.post_id) < (?, ?) ORDER BY f.created_at DESC, f.post_id DESC LIMIT ?");
const post = db.query<PostRow, [number]>("SELECT p.id, p.title, p.body, p.comment_count AS commentCount, p.created_at AS createdAt, u.id AS authorId, u.name AS authorName FROM posts p JOIN users u ON u.id = p.user_id WHERE p.id = ?");
const comments = db.query<CommentRow, [number]>("SELECT c.id, c.body, c.created_at AS createdAt, u.id AS authorId, u.name AS authorName FROM comments c JOIN users u ON u.id = c.user_id WHERE c.post_id = ? ORDER BY c.id DESC LIMIT 20");
const update = db.query<unknown, [number]>("UPDATE posts SET comment_count = comment_count + 1 WHERE id = ?");
const insert = db.query<{ id: number }, [number, number, string, number]>("INSERT INTO comments (post_id, user_id, body, created_at) VALUES (?, ?, ?, ?) RETURNING id");
export const sqliteVersion = db.query<{ version: string }, []>("SELECT sqlite_version() AS version").get()!.version;

export class PostNotFound extends Error {}
const createComment = db.transaction((postId: number, userId: number, body: string, createdAt: number) => {
  if (update.run(postId).changes === 0) throw new PostNotFound();
  return insert.get(postId, userId, body, createdAt)!.id;
});

export function listFeed(userId: number, cursor: [number, number], limit: number): PostRow[] {
  return feed.all(userId, cursor[0], cursor[1], limit);
}
export function getPost(id: number): PostRow | null { return post.get(id); }
export function listComments(id: number): CommentRow[] { return comments.all(id); }
export function insertComment(postId: number, userId: number, body: string, createdAt: number): number {
  return createComment.immediate(postId, userId, body, createdAt);
}
export function closeDatabase(): void { db.close(); }
