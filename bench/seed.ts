import { Database } from "bun:sqlite";
import { mkdirSync, rmSync } from "node:fs";
import { resolve } from "node:path";

const path = resolve(import.meta.dir, "../data/seed.db");
mkdirSync(resolve(import.meta.dir, "../data"), { recursive: true });
for (const suffix of ["", "-wal", "-shm"]) rmSync(path + suffix, { force: true });
const db = new Database(path);
db.exec(`PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA foreign_keys=ON;
CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL);
CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), title TEXT NOT NULL, body TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE INDEX posts_user_id_id ON posts(user_id, id DESC);`);
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
function words(length: number): string {
  let text = "";
  while (text.length < length) {
    if (text) text += " ";
    const size = integer(3, 10);
    for (let i = 0; i < size; i++) text += String.fromCharCode(integer(97, 122));
  }
  return text.slice(0, length);
}
const user = db.prepare("INSERT INTO users VALUES (?, ?, ?, ?)");
const post = db.prepare("INSERT INTO posts VALUES (?, ?, ?, ?, ?)");
db.transaction(() => {
  for (let id = 1; id <= 10000; id++) user.run(id, `User ${id}`, `user${id}@example.com`, 1700000000000 + id - 1);
  for (let id = 1; id <= 100000; id++) post.run(id, integer(1, 10000), words(integer(20, 80)), words(integer(200, 2000)), 1700000000000 + 10000 + id - 1);
})();
db.exec("VACUUM; PRAGMA wal_checkpoint(TRUNCATE)");
console.log(JSON.stringify(db.query("SELECT (SELECT count(*) FROM users) AS users, (SELECT count(*) FROM posts) AS posts").get()));
db.close();
