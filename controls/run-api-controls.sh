#!/bin/sh
# Runs the controls through the HTTP API of the container and writes the answers to
# controls/api-results.txt. One container per secret, as a setter would run it.
# Needs the image built as duel-referee:test (or IMAGE=...).
set -u
cd "$(dirname "$0")/.."
IMAGE=${IMAGE:-duel-referee:test}
OUT=controls/api-results.txt
TMP=$(mktemp -d)
trap 'docker rm -f duel-api-control >/dev/null 2>&1; rm -rf "$TMP"' EXIT
printf 'alice token-alice\nbob token-bob\n' > "$TMP/tokens"

start() {
    docker rm -f duel-api-control >/dev/null 2>&1
    mkdir -p "$TMP/state-$1"
    docker run -d --name duel-api-control -p 127.0.0.1:18080:8080 \
        -v "$PWD/controls/src/$1.s:/secret/secret.s:ro" -v "$TMP/tokens:/config/tokens:ro" \
        -v "$TMP/state-$1:/state" "$IMAGE" >/dev/null
    for i in $(seq 1 50); do curl -s -o /dev/null http://127.0.0.1:18080/score && return; sleep 0.2; done
    echo "server did not come up" >> "$OUT"
}

q() {
    echo "\$ POST /query $1  (token-${2:-alice})" >> "$OUT"
    curl -s -X POST -H "Authorization: Bearer token-${2:-alice}" -d "{\"input\": \"$1\"}" \
        http://127.0.0.1:18080/query >> "$OUT"
}

check() {
    echo "\$ POST /check $1" >> "$OUT"
    python3 -c 'import json,sys; print(json.dumps({"source": open(sys.argv[1]).read()}))' "controls/src/$1.s" |
        curl -s -X POST -H "Authorization: Bearer token-alice" --data-binary @- http://127.0.0.1:18080/check >> "$OUT"
}

{
    echo "duel-referee API controls, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "image: $(docker image inspect -f '{{.Id}}' "$IMAGE")"
    echo "redux: $(docker run --rm "$IMAGE" cat /opt/redux.sha256)"
    echo
} > "$OUT"

echo "== 1. positive control: secret addiu v0, a0, 1" >> "$OUT"
start positive
for i in 0 1 7fffffff 80000000 ffffffff; do q $i; done
echo "== 2. must-trip: secret lw v0, 0(a0)" >> "$OUT"
start memaccess
for i in 0 1f800000 1f801070 bfc00000 60000000; do q $i; done
echo "== 3. TRAP: secret add v0, a0, a0" >> "$OUT"
start trap
for i in 7fffffff 1; do q $i; done
echo "== 4. TIMEOUT: secret b . / nop" >> "$OUT"
start timeout
q 0
echo "== 5. check, log and auth: secret popcount" >> "$OUT"
start popcount
q ffffffff
check popcount-alt
check popcount-wrong
check toolong
q 1 bob
echo "\$ POST /query 0  (token-nobody)" >> "$OUT"
curl -s -X POST -H "Authorization: Bearer token-nobody" -d '{"input": "0"}' http://127.0.0.1:18080/query >> "$OUT"
echo "\$ GET /score" >> "$OUT"
curl -s -H "Authorization: Bearer token-bob" http://127.0.0.1:18080/score >> "$OUT"
echo "\$ GET /log  (token-alice)" >> "$OUT"
curl -s -H "Authorization: Bearer token-alice" http://127.0.0.1:18080/log >> "$OUT"
