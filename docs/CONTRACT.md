# Server contract

Every server variant implements exactly this. The harness and the conformance check depend on it byte-for-byte.

The benchmark compares runtimes (Go, Bun, Node), not SQLite. SQLite is only the data source because it has negligible latency, so every query is a cheap indexed lookup and most of each request's time is language-side work: auth, validation, shaping data, JSON.

## Code standard
Write it the way an experienced engineer would ship an optimised production service in that runtime: idiomatic, clean, maintainable, using the runtime's standard tools and well-established libraries. Sensible performance choices (prepared statements, connection pools, avoiding needless copies, the runtime's fast native APIs) are expected. Benchmark-only hacks are not allowed: no caching responses or query results, no precomputed outputs, no skipping validation/auth, no hand-rolled JSON writers, no unsafe tricks, no special-casing the harness's inputs.

## Process
- Env: `PORT` (default 3000), `DB_PATH` (required), `JWT_SECRET` (required), bind `127.0.0.1` only.
- JS clusters: `WORKERS` (process count, default 1).
- Ready when `GET /health` returns 200. SIGTERM/SIGINT exits cleanly (cluster launchers kill their children).
- Never create the schema; the DB file is pre-seeded by `bench/seed.ts`. Fail fast if the DB file or `JWT_SECRET` is missing.

## SQLite settings (identical for every connection, every variant)
```
PRAGMA busy_timeout = 5000;
PRAGMA journal_mode = WAL;        -- already persisted by seed, set anyway
PRAGMA synchronous = NORMAL;
PRAGMA cache_size = -16000;       -- 16 MB per connection
PRAGMA temp_store = MEMORY;
```
Statements are prepared once and reused. Write statements are stepped to `SQLITE_DONE`: an `INSERT … RETURNING` reset after its first row commits inside `sqlite3_reset` and skips SQLite's WAL autocheckpoint, so read it with an all-rows API in drivers where that matters. Reads may use first-row APIs.

## Schema (created by seed)
```sql
CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL);
CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), title TEXT NOT NULL, body TEXT NOT NULL, comment_count INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL);
CREATE TABLE comments (id INTEGER PRIMARY KEY, post_id INTEGER NOT NULL REFERENCES posts(id), user_id INTEGER NOT NULL REFERENCES users(id), body TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE INDEX comments_post_id_id ON comments(post_id, id DESC);
CREATE TABLE feed_items (user_id INTEGER NOT NULL, created_at INTEGER NOT NULL, post_id INTEGER NOT NULL, PRIMARY KEY (user_id, created_at, post_id)) WITHOUT ROWID;
```
Seed (deterministic): 10,000 users; each follows 20 others; 100,000 posts (bodies 300–2000 chars of lowercase ASCII words separated by single spaces, ~1 in 15 words is a hashtag like `#word`); `feed_items` is the fan-out of each user's followees' posts (~2M rows); ~500,000 comments (bodies 20–300 chars, same alphabet), and `posts.comment_count` matches. `created_at` is unix ms, unique per table. All text is ASCII.

## SQL (use exactly these)
- feed: `SELECT p.id, p.title, p.body, p.comment_count, p.created_at, u.id, u.name FROM feed_items f JOIN posts p ON p.id = f.post_id JOIN users u ON u.id = p.user_id WHERE f.user_id = ? AND (f.created_at, f.post_id) < (?, ?) ORDER BY f.created_at DESC, f.post_id DESC LIMIT ?` (first page binds `9007199254740991, 9007199254740991`)
- post: `SELECT p.id, p.title, p.body, p.comment_count, p.created_at, u.id, u.name FROM posts p JOIN users u ON u.id = p.user_id WHERE p.id = ?`
- comments: `SELECT c.id, c.body, c.created_at, u.id, u.name FROM comments c JOIN users u ON u.id = c.user_id WHERE c.post_id = ? ORDER BY c.id DESC LIMIT 20`
- comment insert, in one `BEGIN IMMEDIATE` transaction:
  1. `UPDATE posts SET comment_count = comment_count + 1 WHERE id = ?` — 0 rows changed → roll back, 404
  2. `INSERT INTO comments (post_id, user_id, body, created_at) VALUES (?, ?, ?, ?) RETURNING id`

Selected columns may be aliased however the driver needs; the order and values are what matter.

## Auth
Every route except `/health` and `/meta` requires `Authorization: Bearer <jwt>`. The JWT is compact HS256 (`header.payload.signature`, base64url without padding), signed with `JWT_SECRET` (UTF-8 bytes) by the harness. Verify:
1. Exactly three non-empty segments; each decodes as base64url without padding.
2. Header JSON is an object whose `alg` is `"HS256"`.
3. HMAC-SHA256 over `header.payload` (the ASCII segments as sent) matches the signature, compared in constant time.
4. Payload JSON is an object with `sub` (integer 1..2^53-1), `name` (string), `iss` exactly `"gbb"`, `exp` (integer 0..2^53-1) with `exp * 1000 > now`.
Any failure, a missing header, or a scheme other than `Bearer ` → 401 `{"error":"unauthorized"}`. Use each framework's idiomatic auth hook; when a request has both bad auth and an invalid body/query, either the 401 or the 400 is acceptable (frameworks order parsing and auth differently, and load traffic never hits this). Implement verification as a small module on the runtime's standard crypto (Go `crypto/hmac` + `crypto/sha256`, `node:crypto` `createHmac` + `timingSafeEqual` in Bun and Node) so every variant does the same work; JWT libraries differ too much in what they do per call to compare fairly.

## Derived fields (computed in code, per post, every time)
On `body` (ASCII):
- `wordCount`: number of maximal runs of characters other than space.
- `readingMinutes`: `max(1, ceil(wordCount / 200))`.
- `tags`: scan words left to right; a word is a tag if it starts with `#` followed by one or more `[a-z0-9_]` and nothing else. Tag value is the part after `#`. Unique, in first-appearance order, at most 5. No tags → `[]`.
- `excerpt` (feed only): if `body.length <= 200` the whole body; otherwise take the first 200 chars, cut at the last space within them (drop the space and everything after it; if there is no space keep all 200), then append `...`.

## Endpoints
All JSON responses: `Content-Type: application/json` (charset suffix allowed), compact JSON, no trailing newline, keys in the order shown. Error body is always `{"error":"<message>"}`.

### `GET /health`
200 `text/plain` body `ok`. No auth.

### `GET /meta`
200 `{"runtime":"…","framework":"…","sqlite":"<sqlite_version()>"}`. No auth.

### `GET /feed?limit=N&cursor=C`
- `limit`: absent → 20; else integer 1..50, decimal digits only → otherwise 400 `invalid limit`.
- `cursor`: absent → first page; else base64url (no padding) of `"<createdAt>:<postId>"`, both decimal digits only, 1..2^53-1 → otherwise 400 `invalid cursor`.
- Viewer is the JWT `sub`/`name`.
- 200:
```
{"viewer":{"id":1,"name":"User 1"},"items":[{"id":5,"title":"…","excerpt":"…","wordCount":120,"readingMinutes":1,"tags":["a","b"],"commentCount":3,"createdAt":1700000000000,"author":{"id":9,"name":"User 9"}}],"nextCursor":"…"}
```
`nextCursor` is the cursor of the last item (its `feed_items.created_at`, which equals the post's `created_at`, and post id) when exactly `limit` items were returned, else `null`.

### `GET /posts/:id`
- `id` decimal digits only, 1..2^53-1 → otherwise 400 `invalid id`. Missing → 404 `not found`.
- 200:
```
{"post":{"id":5,"title":"…","body":"…","wordCount":120,"readingMinutes":1,"tags":[],"commentCount":3,"createdAt":1700000000000,"author":{"id":9,"name":"User 9"}},"comments":[{"id":77,"body":"…","createdAt":1700000000000,"author":{"id":4,"name":"User 4"}}]}
```
`comments` is the 20 newest, newest first.

### `POST /posts/:id/comments`
- Path id as above (400 `invalid id`).
- Body JSON `{"body": string}` with length 1..2000; malformed JSON, not an object, missing/non-string `body`, or out-of-range length → 400 `invalid body`. Body over 64 KiB → 413 (body unspecified). Extra keys are ignored.
- Author is the JWT viewer. `createdAt` is server `now` in ms.
- Post doesn't exist → 404 `not found`.
- 201 `{"id":…,"postId":5,"body":"…","createdAt":…,"author":{"id":1,"name":"User 1"}}`

Unknown routes → 404 (body unspecified); wrong method → 404 or 405. Any other DB error → 500 `{"error":"internal"}`, including SQLITE_BUSY after the busy timeout.

Out of scope (each framework's standard behaviour is fine, conformance doesn't test them): non-ASCII escaping differences in JSON output, JSON key case-sensitivity, percent-encoded path segments, request charsets other than UTF-8, wrong-method responses.
