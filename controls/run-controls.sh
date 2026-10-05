#!/bin/sh
# Runs every control and writes what the referee actually answered to controls/results.txt.
# Needs DUEL_REDUX and DUEL_BIOS set, like duel itself.
set -u
cd "$(dirname "$0")/.."
OUT=controls/results.txt
STATE=$(mktemp -d)
export DUEL_STATE="$STATE"
trap 'rm -rf "$STATE"' EXIT

run() {
    echo "\$ $*" >> "$OUT"
    "$@" >> "$OUT" 2>&1
    echo "exit $?" >> "$OUT"
    echo >> "$OUT"
}

{
    echo "duel-referee controls, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "redux: $(git -C "$(dirname "$DUEL_REDUX")" log -1 --format='%h %s' 2>/dev/null)"
    echo "bios:  openbios.bin, sha256 $(sha256sum "$DUEL_BIOS" | cut -c1-16)"
    echo
    echo "== 1. positive control: addiu v0, a0, 1"
} > "$OUT"
run ./duel run controls/src/positive.s 0 1 7fffffff 80000000 ffffffff

echo "== 2. must-trip: lw refused with MEMACCESS (both gates, then each gate alone)" >> "$OUT"
run ./duel run controls/src/memaccess.s 0 1f800000 1f801070 bfc00000 fffe0130 60000000 a0100000
run env DUEL_DECODER=0 ./duel run controls/src/memaccess.s 0 1f800000 1f801070 bfc00000 fffe0130 60000000 a0100000
run ./duel run controls/src/store.s 0
run env DUEL_DECODER=0 ./duel run controls/src/store.s 0
run ./duel run controls/src/load-delay-slot.s 1f801070

echo "== 3. TRAP: add overflow on 0x7fffffff (plain, and in a delay slot), syscall in a delay slot" >> "$OUT"
run ./duel run controls/src/trap.s 7fffffff 1 80000000
run ./duel run controls/src/trap-delay-slot.s 7fffffff 1 80000000
run ./duel run controls/src/syscall-delay-slot.s 0

echo "== 4. TIMEOUT: infinite loop" >> "$OUT"
run ./duel run controls/src/timeout.s 0 1

echo "== 5. other verdicts and the length limit" >> "$OUT"
run ./duel run controls/src/escape.s 0 60000000 a0100010
run ./duel run controls/src/toolong.s 0

echo "== 6. query, check (pass, fail), log" >> "$OUT"
run ./duel set controls/src/popcount.s
run ./duel query alice 0
run ./duel query alice ffffffff
run ./duel check alice controls/src/popcount-alt.s
run ./duel check alice controls/src/popcount-wrong.s
run ./duel check alice controls/src/toolong.s
run ./duel score alice
echo "\$ cat state/alice.jsonl" >> "$OUT"
cat "$STATE/alice.jsonl" >> "$OUT"
