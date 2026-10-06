# duel-referee

Referee for a two-player MIPS game. The setter writes a leaf function for the
PlayStation's R3000; the solver queries it with inputs, sees the outputs, and has
to reconstruct it exactly. Score is the number of queries, lower wins.

## Rules

- The function is at most 32 instructions, delay slots included. Trailing zero
  words are not counted (the code region is zero-filled, so they change nothing).
- Input in `a0`, output in `v0`, return with `jr ra`. Every other GPR, `hi` and
  `lo` start at 0. `ra` holds the return address.
- The code is loaded at `0xa0100000` (KSEG1). Return is detected when the CPU
  reaches `0xa0200000`, plus one instruction so a pending load delay reaches `v0`.
- No memory access. Any load or store, to any address, ends the run with
  `MEMACCESS <address>` before it executes. Instruction fetch does not count.
- More than 10,000 executed instructions ends the run with `TIMEOUT`.
- An exception ends the run with `TRAP <cause>`: `Ov` for overflow on
  `add`/`addi`/`sub`, `Break`, `Syscall`, `AdEL` for a misaligned jump, `RI`, and
  so on. Leaving the 32-word region any other way is `ESCAPE <pc>`.
- Each query costs 1. Each `check` costs 1: the candidate is run against the
  original on 0, 1, 0x7fffffff, 0x80000000, 0xffffffff and 10,000 random inputs.
  It must match the verdict on every input, and `v0` on every `OK`. A failed check
  shows the first mismatching input and both answers. A candidate over 32 words
  is rejected without spending a query.
- Interrupts are disabled. CP0 and CP2 are reset before every run, so `mtc0`
  and GTE state do not carry over from one query to the next.

## Use

```
export DUEL_REDUX=/path/to/pcsx-redux DUEL_BIOS=/path/to/openbios.bin
./duel set secret.s              # setter
./duel query alice 7fffffff      # solver, logs to state/alice.jsonl
./duel check alice guess.s
./duel score
./duel run any.s 0 1 2           # free, unlogged, for testing
```

`.s` files go through `mipsel-none-elf-as` with `.set noreorder` and `.set noat`
prepended, so delay slots are exactly what was written and no macro sneaks in a
hidden `$at`. `.bin` files are raw little-endian words.

## Hosting a round

The setter runs the referee as a container, with the function mounted in at run time:

```
docker build -t duel-referee .
printf 'alice <token>\n' > tokens          # one "<player> <token>" line per solver
docker run -d -p 8080:8080 \
    -v $PWD/secret.s:/secret/secret.s:ro -v $PWD/tokens:/config/tokens:ro \
    -v $PWD/state:/state duel-referee
```

Solvers then call it with `Authorization: Bearer <token>`:

```
curl -X POST -H "Authorization: Bearer $T" -d '{"input": "7fffffff"}' http://host:8080/query
curl -X POST -H "Authorization: Bearer $T" -d '{"source": "jr $ra\n addiu $v0, $a0, 1"}' http://host:8080/check
curl -H "Authorization: Bearer $T" http://host:8080/score
curl -H "Authorization: Bearer $T" http://host:8080/log
```

`/check` also takes `{"bin": "<hex bytes>"}`. The logs in `state/` are the scoreboard. The image
pins nothing by default and takes the Redux dev build current at build time; its sha256 is in
`/opt/redux.sha256`, and `--build-arg REDUX_URL=...` pins a specific one.
`controls/run-api-controls.sh` replays the controls through the API into `controls/api-results.txt`.

## How it works

`referee.lua` runs inside PCSX-Redux (`-interpreter -debugger -testmode -no-ui`).
After openbios reaches the shell it takes over the CPU. One execution breakpoint
over the whole address space sees every instruction before it runs; read and
write breakpoints over the whole address space catch data accesses. An opcode
check in the execution hook catches loads and stores as well. `DUEL_DECODER=0`
turns that check off, and `controls/results.txt` shows the breakpoints alone
still refuse every load and store tried.

Three Redux interpreter behaviours the referee works around:

- With the debugger on, a read from an unmapped address pauses the emulator. The
  debugger fetches the next instruction word itself, so a jump to unmapped memory
  would hang. `referee.lua` answers those reads from Lua.
- `add`/`addi`/`sub` overflow in a branch delay slot sets Cause and EPC, but the
  pending branch overwrites the jump to the exception vector. The referee checks
  Cause on every instruction, so the trap is still reported.
  [grumpycoders/pcsx-redux#2225](https://github.com/grumpycoders/pcsx-redux/issues/2225).
- `syscall`/`break` in a taken branch's delay slot aborts the emulator. The
  referee reports the trap itself (ExcCode 8 or 9) without executing it.
  [grumpycoders/pcsx-redux#2224](https://github.com/grumpycoders/pcsx-redux/issues/2224).

The fix for both is [grumpycoders/pcsx-redux#2226](https://github.com/grumpycoders/pcsx-redux/pull/2226), open.
The workarounds stay so the referee also runs on builds without it.

Overflow only traps when Redux runs with `-debugger`, which `duel` always passes.

## Controls

`controls/run-controls.sh` runs the controls and writes the referee's actual
answers to `controls/results.txt`: a positive control, `lw` and `sw` refused,
`add` overflow on 0x7fffffff, an infinite loop, escapes, the length limit, and a
query/check/log session.
