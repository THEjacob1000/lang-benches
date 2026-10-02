#!/usr/bin/env bash
# Conformance-checks the server on 127.0.0.1:$PORT: bench/conformance.sh VARIANT.
# Go runs first; later variants diff their responses against it.
set -euo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")/.."
variant=$1
db=/scratch/db.sqlite
TMP=$(mktemp -d)
lock_pid=""
cleanup() {
  if [[ -n $lock_pid ]]; then kill "$lock_pid" 2>/dev/null || true; wait "$lock_pid" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT
read -r token < data/tokens.txt
JWT_SECRET="$JWT_SECRET" bun -e '
import {createHmac} from "node:crypto";
const base={sub:1,name:"User 1",iss:"gbb",exp:Math.floor(Date.now()/1000)+3600};
function mint(payload,header={alg:"HS256"}) { const input=[header,payload].map(v=>Buffer.from(JSON.stringify(v)).toString("base64url")).join("."); return input+"."+createHmac("sha256",process.env.JWT_SECRET).update(input).digest("base64url"); }
for (const [name,payload,header] of [["expired",{...base,exp:1}], ["issuer",{...base,iss:"other"}], ["float",{...base,sub:1.5}], ["none",base,{alg:"none"}], ["name",{...base,name:1}], ["sub",{...base,sub:0}], ["exp",{...base,exp:1.5}], ["header",base,[]], ["payload",[]]]) console.log(name+" "+mint(payload,header));
for (const sub of ["1",9007199254740992]) console.log("sub-"+sub+" "+mint({...base,sub}));
console.log("exp-string "+mint({...base,exp:"2100000000"}));
const valid=mint(base); const alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
console.log("noncanonical "+valid.slice(0,-1)+alphabet[alphabet.indexOf(valid.at(-1))+1]);
' > "$TMP/bad-tokens"
request() {
  local label=$1 method=$2 path=$3 expected=$4 payload=${5:-} auth=${6:-Bearer $token} unspecified=${7:-false}
  local status body type before after
  local -a args=(-sS --max-time 15 -D "$TMP/headers" -o "$TMP/body" -w '%{http_code}' -X "$method")
  if [[ $auth != missing ]]; then args+=(-H "Authorization: $auth"); fi
  if [[ $method == POST ]]; then args+=(-H 'Content-Type: application/json' --data-binary "$payload"); fi
  if [[ $expected == 201 ]]; then before=$(date +%s%3N); fi
  status=$(curl "${args[@]}" "http://127.0.0.1:$PORT$path")
  if [[ $expected == 201 ]]; then after=$(date +%s%3N); fi
  body=$(cat "$TMP/body"; printf '.'); body=${body%.}
  [[ $status == "$expected" ]] || { echo "$variant $label: expected $expected, got $status: $body" >&2; exit 1; }
  type=$(tr -d '\r' < "$TMP/headers" | while IFS= read -r line; do if [[ ${line,,} == content-type:* ]]; then line=${line#*:}; line=${line# }; printf '%s' "${line%%;*}"; fi; done)
  if [[ $unspecified == true ]]; then type='<unspecified>'; body='<unspecified>'
  elif [[ $path == /health ]]; then [[ $type == text/plain && $body == ok ]]
  else
    [[ $type == application/json && $body == "$(jq -c . "$TMP/body")" ]] || { echo "$variant $label: noncompact JSON or content type" >&2; exit 1; }
    case "$status" in
      401) [[ $body == '{"error":"unauthorized"}' ]] ;;
      404) [[ $body == '{"error":"not found"}' ]] ;;
      500) [[ $body == '{"error":"internal"}' ]] ;;
      400) case "$label" in limit-*) message='invalid limit';; cursor-*) message='invalid cursor';; id-*) message='invalid id';; *) message='invalid body';; esac; [[ $body == "{\"error\":\"$message\"}" ]] ;;
      201) jq -e --argjson before "$before" --argjson after "$after" 'keys_unsorted == ["id","postId","body","createdAt","author"] and .author == {id:1,name:"User 1"} and .createdAt >= $before and .createdAt <= $after' "$TMP/body" >/dev/null; body=$(jq -c 'del(.createdAt)' "$TMP/body") ;;
    esac
    if [[ $path == /meta ]]; then jq -e 'keys_unsorted == ["runtime","framework","sqlite"] and all(.[]; type=="string" and length>0)' "$TMP/body" >/dev/null; body='<variant metadata>'; fi
    if [[ $label == post-after ]]; then body=$(jq -c 'del(.comments[0].createdAt)' "$TMP/body"); fi
  fi
  printf '%s|%s|%s|%s\n' "$label" "$status" "$type" "$body" >> "/scratch/check/$variant.responses"
}
request health GET /health 200 '' missing
request meta GET /meta 200 '' missing
case "$variant" in
  go|go-4) jq -e '.runtime|startswith("go")' "$TMP/body" >/dev/null; [[ $(jq -r .framework "$TMP/body") == net/http ]] ;;
  rust) jq -e '(.runtime|startswith("rust ")) and (.framework|startswith("axum "))' "$TMP/body" >/dev/null ;;
  bun|bun-1) jq -e '.runtime|startswith("bun ")' "$TMP/body" >/dev/null; [[ $(jq -r .framework "$TMP/body") == bun ]] ;;
  elysia) jq -e '(.runtime|startswith("bun ")) and (.framework|startswith("elysia "))' "$TMP/body" >/dev/null ;;
  node) jq -e '(.runtime|startswith("node ")) and (.framework|startswith("express "))' "$TMP/body" >/dev/null ;;
esac
for auth in missing 'Basic abc' 'bearer abc' 'Bearer !!!.abc.def' "Bearer ${token%.*}.AA" 'Bearer a.b' 'Bearer a.b.c.d' "Bearer $token=" 'Bearer ..'; do request "auth-$auth" GET /feed 401 '' "$auth"; done
while read -r label bad; do request "auth-$label" GET /feed 401 '' "Bearer $bad"; done < "$TMP/bad-tokens"
request auth-post GET /posts/1 401 '' missing
request auth-comment POST /posts/1/comments 401 '{"body":"ok"}' 'Bearer bad'
status=$(curl -sS --max-time 15 -o "$TMP/body" -w '%{http_code}' -H 'Authorization: Bearer bad' -H 'Content-Type: application/json' --data-binary '{' "http://127.0.0.1:$PORT/posts/1/comments")
case "$status" in 401) [[ $(cat "$TMP/body") == '{"error":"unauthorized"}' ]] ;; 400) [[ $(cat "$TMP/body") == '{"error":"invalid body"}' ]] ;; *) echo "$variant bad-auth/body: unexpected $status" >&2; exit 1 ;; esac
cursor=''
for page in 1 2 3; do
  path=/feed; if [[ -n $cursor ]]; then path="/feed?cursor=$cursor"; fi
  request "feed-$page" GET "$path" 200
  jq -e 'keys_unsorted == ["viewer","items","nextCursor"] and .viewer == {id:1,name:"User 1"} and (.items|length)==20 and all(.items[]; keys_unsorted == ["id","title","excerpt","wordCount","readingMinutes","tags","commentCount","createdAt","author"])' "$TMP/body" >/dev/null
  jq -c '[.items[].id]' "$TMP/body" >> "$TMP/pages"
  cursor=$(jq -r .nextCursor "$TMP/body")
done
[[ $(jq -s 'add | length == (unique|length)' "$TMP/pages") == true ]]
request feed-one GET '/feed?limit=1' 200
[[ $(jq '.items|length' "$TMP/body") == 1 ]]
request feed-max GET '/feed?limit=50' 200
[[ $(jq '.items|length' "$TMP/body") == 50 ]]
for limit in 0 51 -1 x 1.5 '' 9007199254740992 '%2B1' 1e1 0x1 '%201' '1%20'; do request "limit-$limit" GET "/feed?limit=$limit" 400; done
for cursor in '' '!!!' 'MQ==' 'MDox' 'MTow' 'LTE6MQ' 'MToxLjU' 'OTAwNzE5OTI1NDc0MDk5Mjox' 'MToxOjE' 'MToxMR' 'MToxMg==' 'KzE6MQ'; do request "cursor-$cursor" GET "/feed?cursor=$cursor" 400; done
request feed-end GET '/feed?cursor=MTox' 200
[[ $(cat "$TMP/body") == '{"viewer":{"id":1,"name":"User 1"},"items":[],"nextCursor":null}' ]]
request post GET /posts/1 200
jq -e 'keys_unsorted == ["post","comments"] and (.post|keys_unsorted)==["id","title","body","wordCount","readingMinutes","tags","commentCount","createdAt","author"] and .post.id==1 and all(.comments[]; keys_unsorted==["id","body","createdAt","author"])' "$TMP/body" >/dev/null
count=$(jq .post.commentCount "$TMP/body")
for id in 0 -1 abc 1.5 9007199254740992 +1 1e1 0x1 '%201' '1%20'; do request "id-get-$id" GET "/posts/$id" 400; request "id-create-$id" POST "/posts/$id/comments" 400 '{"body":"ok"}'; done
request post-missing GET /posts/100001 404
request post-max GET /posts/9007199254740991 404
request comment-missing POST /posts/100001/comments 404 '{"body":"ok"}'
request comment-max POST /posts/9007199254740991/comments 404 '{"body":"ok"}'
request unknown GET /unknown 404 '' "Bearer $token" true
request missing-id GET /posts/ 404 '' "Bearer $token" true
status=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $token" "http://127.0.0.1:$PORT/feed"); [[ $status == 404 || $status == 405 ]]
request create POST /posts/1/comments 201 '{"body":"A valid comment","extra":true}'
comment_id=$(jq .id "$TMP/body")
[[ $(jq -c 'del(.id,.createdAt)' "$TMP/body") == '{"postId":1,"body":"A valid comment","author":{"id":1,"name":"User 1"}}' ]]
request post-after GET /posts/1 200
jq -e --argjson count "$count" --argjson id "$comment_id" '.post.commentCount==$count+1 and .comments[0].id==$id and .comments[0].body=="A valid comment" and .comments[0].author=={id:1,name:"User 1"}' "$TMP/body" >/dev/null
for payload in '{' null '[]' '["ok"]' '{}' '{"body":false}' '{"body":null}' '{"body":1}' '{"body":""}'; do request "body-$payload" POST /posts/1/comments 400 "$payload"; done
request body-long POST /posts/1/comments 400 "$(jq -nc '{body:("x"*2001)}')"
request body-min POST /posts/2/comments 201 '{"body":"x"}'
request body-max POST /posts/2/comments 201 "$(jq -nc '{body:("x"*2000)}')"
request oversized POST /posts/1/comments 413 "$(jq -nc '{body:("x"*71680)}')" "Bearer $token" true
DB_PATH="$db" LOCK_READY="$TMP/locked" bun -e 'import {Database} from "bun:sqlite"; const db=new Database(process.env.DB_PATH); db.exec("BEGIN IMMEDIATE"); await Bun.write(process.env.LOCK_READY,"ready"); await Bun.sleep(30000); db.exec("ROLLBACK"); db.close();' & lock_pid=$!
for ((attempt=0; attempt<100; attempt++)); do [[ -f $TMP/locked ]] && break; sleep 0.05; done
[[ -f $TMP/locked ]]
request busy POST /posts/1/comments 500 '{"body":"ok"}'
kill "$lock_pid"; wait "$lock_pid" 2>/dev/null || true; lock_pid=''; rm "$TMP/locked"
DB_PATH="$db" bun -e 'import {Database} from "bun:sqlite"; const db=new Database(process.env.DB_PATH); db.exec("CREATE TRIGGER fail_comment BEFORE INSERT ON comments BEGIN SELECT RAISE(ABORT, '\''forced internal error'\''); END"); db.close();'
request internal POST /posts/1/comments 500 '{"body":"ok"}'
if [[ $variant != go ]]; then diff -u /scratch/check/go.responses "/scratch/check/$variant.responses"; fi
