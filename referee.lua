-- Duel referee, runs inside PCSX-Redux (interpreter, debugger enabled).
--
-- Started by the `duel` wrapper as:
--   pcsx-redux -no-ui -testmode -interpreter -debugger -run -bios <bios> -dofile referee.lua
-- with DUEL_JOB pointing at a job file and DUEL_OUT at the result file.
--
-- The job file is a Lua chunk returning:
--   { phases = { { code = { w0, w1, ... }, inputs = { i0, i1, ... } }, ... } }
-- Every phase loads its code at CODE_BASE and runs it once per input.
-- One result line per (phase, input) goes to DUEL_OUT:
--   <phase> <index> <input> OK <v0> <count>
--   <phase> <index> <input> TRAP <excode> <epc> <count>
--   <phase> <index> <input> MEMACCESS <addr> <detectors> <count>
--   <phase> <index> <input> TIMEOUT <count>
--   <phase> <index> <input> ESCAPE <pc> <count>
-- followed by a final "DONE <runs>" line.

local ffi = require('ffi')
local bit = require('bit')

local CODE_BASE = 0xa0100000 -- KSEG1, uncached: patched words are seen at the next fetch
local CODE_WORDS = 32
local CODE_END = CODE_BASE + CODE_WORDS * 4
local PAD = 0xa0200000 -- return address: nop at PAD, run ends when pc reaches PAD + 4
-- Runs start through `j CODE_BASE; nop` here, so the debugger checks the function's first
-- instruction like every other one (a direct pc write would skip the check for that one).
local TRAMP = 0xa0200010
-- One-time stub run before the first query: masks and acknowledges every interrupt source in
-- I_MASK/I_STAT, so a function that sets Status.IEc cannot take a hardware interrupt whose
-- timing depends on how long the referee has been running. With openbios no interrupt was
-- seen even without it (10M instructions with IEc and every IM bit set); it stays so the
-- property does not depend on what the BIOS happened to leave enabled.
local STUB = 0xa0200020
local BUDGET = 10000
local INIT = 0 -- every GPR other than a0 and ra, plus hi and lo
local SHELL = 0x80030000

local regs = nil
local ram32 = nil
local job = nil
local out = nil
local state = 'boot'
local phase = 0
local idx = 0
local run = nil
local curInstrPC = nil
local pendingRestore = nil
local cp0snap = {}
local cp2dsnap = {}
local cp2csnap = {}
local runs = 0
local keep = {} -- breakpoint objects, kept alive against the GC
-- DUEL_DECODER=0 turns off the opcode check so the read/write breakpoints are the only gate
-- (used by the controls to show each gate trips on its own).
local useDecoder = os.getenv('DUEL_DECODER') ~= '0'

local function u32(x)
    x = x % 4294967296
    return x
end

local function hex(x) return string.format('%08x', u32(x)) end

local function ramIndex(addr)
    -- KSEG0/KSEG1/KUSEG RAM, 2MB mirror
    return bit.rshift(bit.band(addr, 0x1fffff), 2)
end

local function readCode(addr) return ram32[ramIndex(addr)] end
local function writeCode(addr, w) ram32[ramIndex(addr)] = w end

local function inCode(pc) return pc >= CODE_BASE and pc < CODE_END end

local function isBranch(w)
    local op = bit.rshift(w, 26)
    if op == 1 or (op >= 2 and op <= 7) then return true end
    if op == 0 then
        local funct = bit.band(w, 0x3f)
        return funct == 8 or funct == 9
    end
    if op >= 0x10 and op <= 0x13 then return bit.band(bit.rshift(w, 21), 0x1f) == 8 end
    return false
end

local function isMemOp(w)
    local op = bit.rshift(w, 26)
    return (op >= 0x20 and op <= 0x26) or (op >= 0x28 and op <= 0x2b) or op == 0x2e or (op >= 0x30 and op <= 0x33) or
               (op >= 0x38 and op <= 0x3b)
end

local function effAddr(w)
    local rs = bit.band(bit.rshift(w, 21), 0x1f)
    local imm = bit.band(w, 0xffff)
    if imm >= 0x8000 then imm = imm - 0x10000 end
    local a = u32(regs.GPR.r[rs] + imm)
    local op = bit.rshift(w, 26)
    if op == 0x22 or op == 0x26 or op == 0x2a or op == 0x2e then a = u32(bit.band(a, 0xfffffffc)) end
    return a
end

local function loadPhaseCode()
    local code = job.phases[phase].code
    for i = 0, CODE_WORDS - 1 do writeCode(CODE_BASE + i * 4, u32(code[i + 1] or 0)) end
end

local function setupRun()
    local input = job.phases[phase].inputs[idx]
    for i = 1, 31 do regs.GPR.r[i] = INIT end
    regs.GPR.n.a0 = u32(input)
    regs.GPR.n.ra = PAD
    regs.GPR.n.hi = INIT
    regs.GPR.n.lo = INIT
    for i = 0, 31 do
        regs.CP0.r[i] = cp0snap[i]
        regs.CP2D.r[i] = cp2dsnap[i]
        regs.CP2C.r[i] = cp2csnap[i]
    end
    regs.CP0.r[13] = 0 -- Cause
    run = { input = u32(input), count = 0, prevBranch = false, verdict = nil, detectors = {}, started = false }
    regs.pc = TRAMP
end

local function finish()
    out:write(string.format('DONE %d\n', runs))
    out:close()
    state = 'done'
    for _, bp in ipairs(keep) do bp:disable() end
    PCSX.pauseEmulator()
    PCSX.quit(0)
end

-- Advance to the next (phase, input); returns false when everything ran.
local function nextRun()
    idx = idx + 1
    while phase == 0 or idx > #job.phases[phase].inputs do
        phase = phase + 1
        idx = 1
        if phase > #job.phases then return false end
        loadPhaseCode()
    end
    setupRun()
    return true
end

local function record()
    local r = run
    local v = r.verdict
    local line
    if v == nil then
        line = string.format('OK %s %d', hex(regs.GPR.n.v0), r.count)
    elseif v.kind == 'TRAP' then
        line = string.format('TRAP %d %s %d', v.excode, hex(v.epc), r.count)
    elseif v.kind == 'MEMACCESS' then
        local d = {}
        if r.detectors.decoder then d[#d + 1] = 'decoder' end
        if r.detectors.breakpoint then d[#d + 1] = 'breakpoint' end
        line = string.format('MEMACCESS %s %s %d', hex(v.addr), table.concat(d, '+'), r.count)
    elseif v.kind == 'TIMEOUT' then
        line = string.format('TIMEOUT %d', r.count)
    elseif v.kind == 'ESCAPE' then
        line = string.format('ESCAPE %s %d', hex(v.pc), r.count)
    end
    out:write(string.format('%d %d %s %s\n', phase, idx, hex(r.input), line))
    runs = runs + 1
end

-- End the live run with a verdict. The redirect to PAD must not happen while a taken
-- branch is pending (the CPU would treat PAD's first instruction as the delay slot and then
-- jump back into the function), so when the instruction about to execute is a delay slot it
-- is replaced by a nop for one step, and the redirect happens at the branch target.
local function abort(verdict, pc)
    run.verdict = verdict
    if run.prevBranch and inCode(pc) then
        pendingRestore = { addr = pc, word = readCode(pc) }
        writeCode(pc, 0)
    else
        regs.pc = PAD
    end
end

local function onExec(address, width, cause)
    local pc = address
    curInstrPC = pc
    if state ~= 'live' then return true end
    if pendingRestore then
        writeCode(pendingRestore.addr, pendingRestore.word)
        pendingRestore = nil
    end
    -- Cause is zeroed at the start of every run, so a nonzero ExcCode means the function raised
    -- an exception. This is checked here rather than only at the vector because the interpreter
    -- loses the vector jump for ADD/ADDI/SUB overflow in a branch delay slot: the pending branch
    -- overwrites the exception pc, leaving only Cause and EPC as evidence.
    local excode = bit.band(bit.rshift(regs.CP0.r[13], 2), 0x1f)
    if run and run.started and not run.verdict and excode ~= 0 then
        run.verdict = { kind = 'TRAP', excode = excode, epc = regs.CP0.r[14] }
        if pc ~= PAD and pc ~= PAD + 4 then
            regs.pc = PAD
            return true
        end
    end
    if pc == PAD then return true end
    if pc == PAD + 4 then
        if run then record() end
        if not nextRun() then finish() end
        return true
    end
    if run == nil then return true end
    if run.verdict then
        -- just stepped over a neutralised delay slot; now it is safe to leave
        regs.pc = PAD
        return true
    end
    if not run.started then
        if pc == TRAMP or pc == TRAMP + 4 then return true end
        run.started = true
    end
    if not inCode(pc) then
        if pc == 0x80000080 or pc == 0xbfc00180 then
            -- only an Int (ExcCode 0) gets here; every other code was caught above
            abort({ kind = 'TRAP', excode = excode, epc = regs.CP0.r[14] }, pc)
        else
            abort({ kind = 'ESCAPE', pc = pc }, pc)
        end
        return true
    end
    run.count = run.count + 1
    local w = readCode(pc)
    if run.count > BUDGET then
        abort({ kind = 'TIMEOUT' }, pc)
        return true
    end
    local op = bit.rshift(w, 26)
    local funct = bit.band(w, 0x3f)
    if op == 0 and (funct == 12 or funct == 13) and run.prevBranch then
        -- SYSCALL/BREAK in a taken branch's delay slot aborts the interpreter (psxSYSCALL and
        -- psxBREAK look for the pending branch in the wrong slot), so the referee raises the
        -- trap itself without executing it: ExcCode 8/9, EPC at the branch, as the CPU would.
        run.verdict = { kind = 'TRAP', excode = funct == 12 and 8 or 9, epc = u32(pc - 4) }
        pendingRestore = { addr = pc, word = w }
        writeCode(pc, 0)
        return true
    end
    if useDecoder and isMemOp(w) then
        run.detectors.decoder = true
        abort({ kind = 'MEMACCESS', addr = effAddr(w) }, pc)
        return true
    end
    run.prevBranch = isBranch(w)
    return true
end

-- Read and write breakpoints span the whole address space. They fire in the same debugger
-- step as onExec, after it, and before the access executes.
local function onData(address, width, cause)
    if state ~= 'live' or run == nil or curInstrPC == nil or not inCode(curInstrPC) then return true end
    run.detectors.breakpoint = true
    if not run.verdict then
        abort({ kind = 'MEMACCESS', addr = address }, curInstrPC)
    elseif run.verdict.kind == 'MEMACCESS' then
        run.verdict.addr = address
    end
    return true
end

local function takeover()
    regs = PCSX.getRegisters()
    ram32 = ffi.cast('uint32_t*', PCSX.getMemPtr())
    local jobPath = os.getenv('DUEL_JOB')
    local outPath = os.getenv('DUEL_OUT')
    job = dofile(jobPath)
    out = assert(io.open(outPath, 'w'))
    for i = 0, 31 do
        cp0snap[i] = regs.CP0.r[i]
        cp2dsnap[i] = regs.CP2D.r[i]
        cp2csnap[i] = regs.CP2C.r[i]
    end
    -- interrupts off, no hardware breakpoints
    cp0snap[12] = u32(bit.band(cp0snap[12], bit.bnot(0x3f)))
    cp0snap[7] = 0
    writeCode(PAD, 0)
    writeCode(PAD + 4, 0)
    writeCode(TRAMP, u32(0x08000000 + bit.rshift(bit.band(CODE_BASE, 0x0fffffff), 2)))
    writeCode(TRAMP + 4, 0)
    -- Width 0 stores the interval [0, 0xffffffff]. The debugger maps any address it cannot place
    -- (unmapped regions) to 0xffffffff and then queries [0xffffffff, 0xffffffff + width - 1],
    -- which wraps; only an interval reaching from 0 to 0xffffffff still overlaps that query.
    keep[#keep + 1] = PCSX.addBreakpoint(0x00000000, 'Exec', 0, 'duel', onExec)
    keep[#keep + 1] = PCSX.addBreakpoint(0x00000000, 'Read', 0, 'duel', onData)
    keep[#keep + 1] = PCSX.addBreakpoint(0x00000000, 'Write', 0, 'duel', onData)
    writeCode(STUB + 0, 0x3c081f80) -- lui  t0, 0x1f80
    writeCode(STUB + 4, 0xad001074) -- sw   zero, 0x1074(t0)   I_MASK
    writeCode(STUB + 8, 0xad001070) -- sw   zero, 0x1070(t0)   I_STAT: acknowledge all
    writeCode(STUB + 12, u32(0x08000000 + bit.rshift(bit.band(PAD, 0x0fffffff), 2))) -- j PAD
    writeCode(STUB + 16, 0)
    state = 'live'
    -- the stub runs with no live query (onExec and onData ignore it), then reaches PAD
    regs.pc = STUB
end

keep[#keep + 1] = PCSX.addBreakpoint(SHELL, 'Exec', 4, 'duel-shell', function()
    if state == 'boot' then
        state = 'takeover'
        local ok, err = pcall(takeover)
        if not ok then
            local f = io.open(os.getenv('DUEL_OUT') or 'duel-error.txt', 'w')
            if f then
                f:write('ERROR ' .. tostring(err) .. '\n')
                f:close()
            end
            PCSX.quit(2)
        end
    end
    return true
end)

-- With the debugger on, a read from an unmapped address pauses the emulator, and nothing would
-- resume it. The debugger itself fetches the next instruction word before the breakpoints run,
-- so a jump to an unmapped address would hang the referee before onExec can call it ESCAPE.
-- Answering the read from Lua takes that path instead of the pause.
function UnknownMemoryRead(address, size)
    return 0xffffffff
end
