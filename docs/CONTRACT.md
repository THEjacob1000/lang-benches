# Server contract

Every server variant implements exactly this. The harness and the conformance check depend on it byte-for-byte.

## Process
- Env: `PORT` (default 3000), `DB_PATH` (required), bind `127.0.0.1` only.
- Bun only: `WORKERS` (process count for the cluster launcher, default 1).
- Ready when `GET /health` returns 200. SIGTERM/SIGINT exits cleanly (cluster launcher kills its children).
- Never create the schema; the DB file is pre-seeded by `bench/seed.ts`. Server must fail fast if the DB file is missing.

## SQLite settings (identical for every connection, every variant)
```
PRAGMA journal_mode = WAL;        -- already persisted by seed, set anyway
PRAGMA synchronous = NORMAL;
PRAGMA busy_timeout = 5000;
PRAGMA foreign_keys = ON;
PRAGMA cache_size = -16000;       -- 16 MB per connection
PRAGMA temp_store = MEMORY;
```
Prepared statements are prepared once and reused (Go: `db.Prepare` at startup; Bun: `db.query()`/`db.prepare()` at module init).

## Schema (created by seed)
```sql
CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL);
CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), title TEXT NOT NULL, body TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE INDEX posts_user_id_id ON posts(user_id, id DESC);
```
Seed: 10,000 users (ids 1..10000), 100,000 posts. `created_at` is unix milliseconds.

## SQL (use exactly these)
- user: `SELECT id, name, email, created_at AS createdAt FROM users WHERE id = ?`
- posts: `SELECT id, user_id AS userId, title, body, created_at AS createdAt FROM posts WHERE user_id = ? ORDER BY id DESC LIMIT ?`
- insert: `INSERT INTO posts (user_id, title, body, created_at) VALUES (?, ?, ?, ?) RETURNING id`

## Endpoints
All JSON responses: `Content-Type: application/json` (charset suffix allowed), compact JSON (no whitespace, no trailing newline), keys in the order shown.
Error body is always `{"error":"<message>"}` with the messages listed below.

| Route | Success | Errors |
|---|---|---|
| `GET /health` | 200 `text/plain` body `ok` | – |
| `GET /meta` | 200 `{"runtime":"<e.g. go1.27.1 / bun 1.4.2>","framework":"<net/http / bun / elysia 2.0.0-beta.20>","sqlite":"<sqlite_version()>"}` | – |
| `GET /users/:id` | 200 `{"id":1,"name":"..","email":"..","createdAt":1700000000000}` | id not a positive integer (decimal digits only, 1..2^53-1) → 400 `invalid id`; missing → 404 `not found` |
| `GET /users/:id/posts?limit=N` | 200 JSON array of posts `{"id":..,"userId":..,"title":"..","body":"..","createdAt":..}` newest first (empty array if user has none or doesn't exist) | bad id → 400 `invalid id`; `limit` present but not an integer in 1..100 → 400 `invalid limit`; default limit 20 |
| `POST /posts` body `{"userId":int,"title":string,"body":string}` | 201 `{"id":..,"userId":..,"title":"..","body":"..","createdAt":<server now ms>}` | malformed JSON / wrong types / missing fields / userId not an integer in 1..2^53-1 / title length not 1..200 / body length not 1..10000 → 400 `invalid body`; FK violation (no such user) → 404 `user not found`; body over 64 KiB → 413 (body unspecified) |

Unknown routes → 404 (body unspecified). String length = JS `.length` semantics are acceptable on both sides for ASCII (harness only sends ASCII).
Any other DB error → 500 `{"error":"internal"}`; SQLITE_BUSY that survives busy_timeout also → 500.
