import { Database } from "bun:sqlite";
import { createHmac } from "node:crypto";
import { mkdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const directory = resolve(import.meta.dir, "../data");
const path = resolve(directory, "seed.db");
mkdirSync(directory, { recursive: true });
for (const suffix of ["", "-wal", "-shm"]) rmSync(path + suffix, { force: true });
const db = new Database(path);
db.exec(`PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA foreign_keys=ON;
CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL);
CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), title TEXT NOT NULL, body TEXT NOT NULL, comment_count INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL);
CREATE TABLE comments (id INTEGER PRIMARY KEY, post_id INTEGER NOT NULL REFERENCES posts(id), user_id INTEGER NOT NULL REFERENCES users(id), body TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE INDEX comments_post_id_id ON comments(post_id, id DESC);
CREATE TABLE feed_items (user_id INTEGER NOT NULL, created_at INTEGER NOT NULL, post_id INTEGER NOT NULL, PRIMARY KEY (user_id, created_at, post_id)) WITHOUT ROWID;`);
let state = 0x12345678;
function random(): number {
  state = (state + 0x6d2b79f5) >>> 0;
  let value = Math.imul(state ^ (state >>> 15), 1 | state);
  value ^= value + Math.imul(value ^ (value >>> 7), 61 | value);
  return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
}
function integer(min: number, max: number): number {
  return min + Math.floor(random() * (max - min + 1));
}
function words(length: number, hashtags = false): string {
  let text = "";
  while (text.length < length) {
    if (text) text += " ";
    if (hashtags && integer(1, 15) === 1) text += "#";
    const size = integer(3, 10);
    for (let i = 0; i < size; i++) text += String.fromCharCode(integer(97, 122));
  }
  return text.slice(0, length).trimEnd();
}
const user = db.prepare("INSERT INTO users VALUES (?, ?, ?, ?)");
const post = db.prepare("INSERT INTO posts VALUES (?, ?, ?, ?, ?, ?)");
const comment = db.prepare("INSERT INTO comments VALUES (?, ?, ?, ?, ?)");
const feed = db.prepare("INSERT INTO feed_items VALUES (?, ?, ?)");
const epoch = 1700000000000;
db.transaction(() => {
  for (let id = 1; id <= 10000; id++) user.run(id, `User ${id}`, `user${id}@example.com`, epoch + id);
  for (let id = 1; id <= 100000; id++) {
    const author = (id - 1) % 10000 + 1;
    post.run(id, author, `Post ${id}`, words(integer(301, 2000), true), 5, epoch + id);
    for (let offset = 1; offset <= 20; offset++) {
      const viewer = (author - offset - 1 + 10000) % 10000 + 1;
      feed.run(viewer, epoch + id, id);
    }
  }
  for (let id = 1; id <= 500000; id++) comment.run(id, (id - 1) % 100000 + 1, integer(1, 10000), words(integer(21, 300)), epoch + id);
})();
db.exec("VACUUM; PRAGMA wal_checkpoint(TRUNCATE)");
console.log(JSON.stringify(db.query("SELECT (SELECT count(*) FROM users) AS users, (SELECT count(*) FROM posts) AS posts, (SELECT count(*) FROM comments) AS comments, (SELECT count(*) FROM feed_items) AS feed_items").get()));
db.close();
const secret = process.env.JWT_SECRET ?? "gbb-dev-secret-change-me";
const now = Math.floor(Date.now() / 1000);
const header = Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url");
const tokens: string[] = [];
for (let id = 1; id <= 10000; id++) {
  const payload = Buffer.from(JSON.stringify({ sub: id, name: `User ${id}`, iss: "gbb", iat: now, exp: now + 10 * 365 * 86400 })).toString("base64url");
  const input = `${header}.${payload}`;
  tokens.push(`${input}.${createHmac("sha256", secret).update(input).digest("base64url")}`);
}
const tokenPath = resolve(directory, "tokens.txt");
writeFileSync(tokenPath, tokens.join("\n") + "\n");
console.log(JSON.stringify({ databaseBytes: statSync(path).size, tokenBytes: statSync(tokenPath).size }));
