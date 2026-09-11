#!/bin/bash
# Security + functional tests for the sharing server.
# Usage: bash scripts/test_sharing.sh [library-path]
set -u
cd "$(dirname "$0")/.."
LIB="${1:-/tmp/facet-sharing-test}"
PORT=8811
swift build -c release >/dev/null 2>&1 || { echo "build failed"; exit 1; }
pkill -f "Facet --serve" 2>/dev/null; sleep 1
./.build/release/Facet --serve --library "$LIB" --port $PORT --account tester:testpassword1 >/tmp/facet-test-serve.log 2>&1 &
SRV=$!; sleep 4
trap 'kill $SRV 2>/dev/null' EXIT

B=http://127.0.0.1:$PORT; J=$(mktemp); pass=0; fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1 — got $2 want $3"; fail=$((fail+1)); fi; }
code(){ curl -s -m 8 -o /dev/null -w "%{http_code}" "$@"; }

echo "[unauthenticated access]"
for p in /api/me /api/photos /api/people /api/photo/1 /thumb/1.jpg /image/1.jpg /download/1 /face/1.jpg; do
  chk "GET $p refused" "$(code $B$p)" "401"; done
chk "GET / serves login" "$(code $B/)" "200"

echo "[credentials]"
chk "wrong password" "$(code -X POST -H 'Content-Type: application/json' -d '{"username":"tester","password":"bad"}' $B/api/login)" "401"
chk "unknown user"   "$(code -X POST -H 'Content-Type: application/json' -d '{"username":"nobody","password":"bad"}' $B/api/login)" "401"
chk "login ok"       "$(code -c $J -X POST -H 'Content-Type: application/json' -d '{"username":"tester","password":"testpassword1"}' $B/api/login)" "200"

echo "[forged sessions]"
for t in abcdef "" "!!!!" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"; do
  chk "forged cookie '$t'" "$(code -H "Cookie: facet_session=$t" $B/api/me)" "401"; done

echo "[read-only surface]"
for m in POST PUT PATCH DELETE; do
  chk "$m /api/photos is not a route" "$(code -b $J -X $m $B/api/photos)" "404"; done

echo "[traversal]"
chk "thumb traversal"    "$(code -b $J "$B/thumb/../../../etc/passwd")" "404"
chk "download traversal" "$(code -b $J "$B/download/../../../etc/passwd")" "404"

echo "[session lifecycle]"
chk "authed read" "$(code -b $J $B/api/me)" "200"
curl -s -m 5 -o /dev/null -b $J -X POST $B/api/logout
chk "refused after logout" "$(code -b $J $B/api/me)" "401"

echo "[throttling]"
for i in 1 2 3 4 5 6; do curl -s -m 5 -o /dev/null -X POST -H 'Content-Type: application/json' -d "{\"username\":\"tester\",\"password\":\"w$i\"}" $B/api/login; done
chk "locked out after 6 failures" "$(code -X POST -H 'Content-Type: application/json' -d '{"username":"tester","password":"testpassword1"}' $B/api/login)" "401"

rm -f $J
echo
echo "pass=$pass fail=$fail"
[ $fail -eq 0 ] || exit 1
