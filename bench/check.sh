#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT"
TMP=$(mktemp -d)
pid=""; lock_pid=""
cleanup() {
  if [[ -n $lock_pid ]]; then kill "$lock_pid" 2>/dev/null || true; wait "$lock_pid" 2>/dev/null || true; fi
  if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT
if curl --fail --silent --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null; then echo "Port $PORT is already occupied" >&2; exit 1; fi
request() {
  local label=$1 method=$2 path=$3 expected=$4 payload=${5:-} unspecified=${6:-false}
  local status type body
  local -a args=(-sS --max-time 15 -D "$TMP/headers" -o "$TMP/body" -w '%{http_code}' -X "$method")
  if [[ $method == POST ]]; then args+=(-H 'Content-Type: application/json' --data-binary "$payload"); fi
  status=$(curl "${args[@]}" "http://127.0.0.1:$PORT$path")
  type=$(tr -d '\r' < "$TMP/headers" | while IFS= read -r line; do
    if [[ ${line,,} == content-type:* ]]; then line=${line#*:}; line=${line# }; printf '%s' "${line%%;*}"; fi
  done)
  body=$(cat "$TMP/body"; printf '.'); body=${body%.}
  if [[ $unspecified != true && $path != /health ]]; then
    [[ $body == "$(jq -c . "$TMP/body")" ]] || { echo "Response is not compact JSON: $label" >&2; exit 1; }
  fi
  if [[ $status != "$expected" ]]; then echo "$variant $label: expected $expected, got $status: $body" >&2; exit 1; fi
  if [[ $unspecified == true ]]; then type='<unspecified>'; body='<unspecified>'
  elif [[ $path == /meta ]]; then
    jq -e 'keys_unsorted == ["runtime","framework","sqlite"] and ([.runtime,.framework,.sqlite] | all(type == "string" and length > 0))' "$TMP/body" >/dev/null
    body='{"runtime":"<runtime>","framework":"<framework>","sqlite":"<sqlite>"}'
  elif [[ $status == 201 ]]; then
    jq -e 'keys_unsorted == ["id","userId","title","body","createdAt"] and (.createdAt | type == "number" and . > 1700000000000)' "$TMP/body" >/dev/null
    body=$(jq -c '.createdAt="<timestamp>"' "$TMP/body")
  fi
  if [[ $unspecified != true ]]; then
    if [[ $path == /health ]]; then
      [[ $type == text/plain && $body == ok ]] || { echo "Invalid health response: $type $body" >&2; exit 1; }
    else
      [[ $type == application/json ]] || { echo "Invalid JSON content type: $type" >&2; exit 1; }
      case "$status" in
        400) case "$label" in id-*) message='invalid id';; limit-*) message='invalid limit';; *) message='invalid body';; esac ;;
        404) if [[ $method == POST ]]; then message='user not found'; else message='not found'; fi ;;
        500) message='internal' ;;
        *) message='' ;;
      esac
      if [[ -n $message && $body != "{\"error\":\"$message\"}" ]]; then echo "Wrong error body: $label $body" >&2; exit 1; fi
    fi
  fi
  printf '%s|%s|%s|%s\n' "$label" "$status" "$type" "$body" >> "$TMP/$variant.responses"
}
read -r -a requested <<< "$VARIANTS"
variants=(go)
for variant in "${requested[@]}"; do if [[ $variant != go ]]; then variants+=("$variant"); fi; done
for variant in "${variants[@]}"; do
  db="$TMP/$variant.db"; cp data/seed.db "$db"
  command_for "$variant"
  NODE_ENV=production DB_PATH="$db" PORT="$PORT" WORKERS=2 GOMAXPROCS=2 "${CMD[@]}" > "$TMP/$variant.log" 2>&1 & pid=$!
  if ! wait_ready; then cat "$TMP/$variant.log" >&2; exit 1; fi
  request health GET /health 200
  request meta GET /meta 200
  request user GET /users/1 200
  [[ $(cat "$TMP/body") == '{"id":1,"name":"User 1","email":"user1@example.com","createdAt":1700000000000}' ]]
  request missing GET /users/999999 404
  posts_user=$(DB_PATH="$db" "$BUN" -e 'import {Database} from "bun:sqlite"; const db=new Database(process.env.DB_PATH,{readonly:true}); console.log(db.query("SELECT user_id FROM posts GROUP BY user_id HAVING count(*) > 20 ORDER BY user_id LIMIT 1").get().user_id); db.close();')
  request posts GET "/users/$posts_user/posts" 200
  jq -e --argjson user "$posts_user" 'length == 20 and all(.[]; .userId == $user and keys_unsorted == ["id","userId","title","body","createdAt"]) and ([.[].id] == ([.[].id] | sort | reverse))' "$TMP/body" >/dev/null
  request posts-limit GET "/users/$posts_user/posts?limit=1" 200
  jq -e 'length == 1' "$TMP/body" >/dev/null
  request posts-limit-max GET "/users/$posts_user/posts?limit=100" 200
  jq -e 'length > 20 and length <= 100' "$TMP/body" >/dev/null
  request posts-missing GET /users/999999/posts 200
  [[ $(cat "$TMP/body") == '[]' ]]
  request max-id-user GET /users/9007199254740991 404
  request max-id-posts GET /users/9007199254740991/posts 200
  for id in 0 -1 abc 1.5 9007199254740992; do
    request "id-user-$id" GET "/users/$id" 400
    request "id-posts-$id" GET "/users/$id/posts" 400
  done
  for limit in 0 101 x 1.5 -1 ''; do request "limit-$limit" GET "/users/1/posts?limit=$limit" 400; done
  request unknown GET /unknown 404 '' true
  request valid POST /posts 201 '{"userId":1,"title":"A valid title","body":"A valid body"}'
  request malformed POST /posts 400 '{'
  request missing-title POST /posts 400 '{"userId":1,"body":"body"}'
  request missing-body POST /posts 400 '{"userId":1,"title":"title"}'
  request missing-user POST /posts 400 '{"title":"title","body":"body"}'
  request string-user POST /posts 400 '{"userId":"1","title":"title","body":"body"}'
  request fractional-user POST /posts 400 '{"userId":1.5,"title":"title","body":"body"}'
  request zero-user POST /posts 400 '{"userId":0,"title":"title","body":"body"}'
  request negative-user POST /posts 400 '{"userId":-1,"title":"title","body":"body"}'
  request unsafe-user POST /posts 400 '{"userId":9007199254740992,"title":"title","body":"body"}'
  request empty-title POST /posts 400 '{"userId":1,"title":"","body":"body"}'
  request wrong-title POST /posts 400 '{"userId":1,"title":1,"body":"body"}'
  request wrong-body POST /posts 400 '{"userId":1,"title":"title","body":false}'
  request empty-body POST /posts 400 '{"userId":1,"title":"title","body":""}'
  request null POST /posts 400 'null'
  request array POST /posts 400 '[]'
  request long-title POST /posts 400 "$(jq -nc '{userId:1,title:("x"*201),body:"body"}')"
  request long-body POST /posts 400 "$(jq -nc '{userId:1,title:"title",body:("x"*10001)}')"
  request under-size-cap POST /posts 400 "$(jq -nc '{userId:1,title:"title",body:("x"*20000)}')"
  request boundary POST /posts 201 "$(jq -nc '{userId:1,title:("x"*200),body:("x"*10000)}')"
  request nonexistent-user POST /posts 404 '{"userId":999999,"title":"title","body":"body"}'
  request max-user POST /posts 404 '{"userId":9007199254740991,"title":"title","body":"body"}'
  request oversized POST /posts 413 "$(jq -nc '{userId:1,title:"title",body:("x"*71680)}')" true
  DB_PATH="$db" LOCK_READY="$TMP/locked" "$BUN" -e 'import {Database} from "bun:sqlite"; const db=new Database(process.env.DB_PATH); db.exec("BEGIN IMMEDIATE"); await Bun.write(process.env.LOCK_READY,"ready"); await Bun.sleep(30000); db.exec("ROLLBACK"); db.close();' & lock_pid=$!
  for ((attempt=0; attempt<100; attempt++)); do
    if [[ -f $TMP/locked ]]; then break; fi
    sleep 0.05
  done
  [[ -f $TMP/locked ]] || { echo 'Writer lock helper failed' >&2; exit 1; }
  request busy POST /posts 500 '{"userId":1,"title":"title","body":"body"}'
  kill "$lock_pid"; wait "$lock_pid" 2>/dev/null || true; lock_pid=""; rm "$TMP/locked"
  DB_PATH="$db" "$BUN" -e 'import {Database} from "bun:sqlite"; const db=new Database(process.env.DB_PATH); db.exec("CREATE TRIGGER fail_insert BEFORE INSERT ON posts BEGIN SELECT RAISE(ABORT, '\''forced internal error'\''); END"); db.close();'
  request internal POST /posts 500 '{"userId":1,"title":"title","body":"body"}'
  kill "$pid"; wait "$pid" 2>/dev/null || true; pid=""
  if [[ $variant != go ]]; then diff -u "$TMP/go.responses" "$TMP/$variant.responses"; fi
  printf '%s: conformance passed\n' "$variant"
done
