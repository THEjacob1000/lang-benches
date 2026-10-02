import Database from "better-sqlite3";
import type { CommentRow, Cursor, PostRow, Viewer } from "./domain.ts";

const path = process.env.DB_PATH;
if (!path) throw new Error("DB_PATH must name an existing database");
export const db = new Database(path, { fileMustExist: true });
db.exec(`
  PRAGMA busy_timeout = 5000;
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = NORMAL;
  PRAGMA foreign_keys = ON;
  PRAGMA cache_size = -16000;
  PRAGMA temp_store = MEMORY;
`);

const feed = db.prepare<[number, number, number, number], PostRow>("SELECT p.id, p.title, p.body, p.comment_count AS commentCount, p.created_at AS createdAt, u.id AS authorId, u.name AS authorName FROM feed_items f JOIN posts p ON p.id = f.post_id JOIN users u ON u.id = p.user_id WHERE f.user_id = ? AND (f.created_at, f.post_id) < (?, ?) ORDER BY f.created_at DESC, f.post_id DESC LIMIT ?");
const post = db.prepare<[number], PostRow>("SELECT p.id, p.title, p.body, p.comment_count AS commentCount, p.created_at AS createdAt, u.id AS authorId, u.name AS authorName FROM posts p JOIN users u ON u.id = p.user_id WHERE p.id = ?");
const comments = db.prepare<[number], CommentRow>("SELECT c.id, c.body, c.created_at AS createdAt, u.id AS authorId, u.name AS authorName FROM comments c JOIN users u ON u.id = c.user_id WHERE c.post_id = ? ORDER BY c.id DESC LIMIT 20");
const increment = db.prepare<[number]>("UPDATE posts SET comment_count = comment_count + 1 WHERE id = ?");
const insert = db.prepare<[number, number, string, number], { id: number }>("INSERT INTO comments (post_id, user_id, body, created_at) VALUES (?, ?, ?, ?) RETURNING id");
export const sqliteVersion = db.prepare<[], { version: string }>("SELECT sqlite_version() AS version").get()!.version;

export class PostNotFoundError extends Error {}

export function getFeed(viewerId: number, cursor: Cursor, limit: number): PostRow[] {
  return feed.all(viewerId, cursor.createdAt, cursor.postId, limit);
}

export function getPost(id: number) {
  const row = post.get(id);
  return row ? { post: row, comments: comments.all(id) } : null;
}

const writeComment = db.transaction((postId: number, body: string, viewer: Viewer) => {
  if (increment.run(postId).changes === 0) throw new PostNotFoundError();
  const createdAt = Date.now();
  // Read through SQLITE_DONE so SQLite can run WAL autocheckpoint.
  const [{ id }] = insert.all(postId, viewer.id, body, createdAt);
  return { id, postId, body, createdAt, author: { id: viewer.id, name: viewer.name } };
});

export function createComment(postId: number, body: string, viewer: Viewer) {
  return writeComment.immediate(postId, body, viewer);
}
