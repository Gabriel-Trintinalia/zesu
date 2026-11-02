const std = @import("std");
const primitives = @import("primitives");
const bytecode = @import("bytecode");
const context = @import("context");
const alloc_mod = @import("zesu_allocator");
const gas_costs = @import("gas_costs.zig");
const opcodes = @import("opcodes/main.zig");
const Gas = @import("gas.zig").Gas;
const Stack = @import("stack.zig").Stack;
const stack_mod = @import("stack.zig");
const Memory = @import("memory.zig").Memory;
const InstructionResult = @import("instruction_result.zig").InstructionResult;
const InterpreterAction = @import("interpreter_action.zig").InterpreterAction;
const CallScheme = @import("interpreter_action.zig").CallScheme;
const CallInputs = @import("interpreter_action.zig").CallInputs;
const CreateInputs = @import("interpreter_action.zig").CreateInputs;
const HostCallInputs = @import("host.zig").CallInputs;
const JournalCheckpoint = @import("context").JournalCheckpoint;
// Lazy imports for dispatch types — pointer-only usage prevents circular dependency issues.
const InstructionContext = @import("instruction_context.zig").InstructionContext;
const Host = @import("host.zig").Host;
const host_mod = @import("host.zig");

/// Input data for current execution context
pub const InputsImpl = struct {
    /// Caller address
    caller: primitives.Address,
    /// Target address
    target: primitives.Address,
    /// Value
    value: primitives.U256,
    /// Data
    data: primitives.Bytes,
    /// Gas limit
    gas_limit: u64,
    /// Call scheme
    scheme: CallScheme,
    /// Is static call
    is_static: bool,
    /// Depth
    depth: usize,

    /// Create new inputs
    pub fn new(
        caller: primitives.Address,
        target: primitives.Address,
        value: primitives.U256,
        data: primitives.Bytes,
        gas_limit: u64,
        scheme: CallScheme,
        is_static: bool,
        depth: usize,
    ) InputsImpl {
        return InputsImpl{
            .caller = caller,
            .target = target,
            .value = value,
            .data = data,
            .gas_limit = gas_limit,
            .scheme = scheme,
            .is_static = is_static,
            .depth = depth,
        };
    }

    /// Create default inputs
    pub fn default() InputsImpl {
        return InputsImpl{
            .caller = [_]u8{0} ** 20,
            .target = [_]u8{0} ** 20,
            .value = 0,
            .data = @as(primitives.Bytes, @constCast(&[_]u8{})),
            .gas_limit = 0,
            .scheme = .call,
            .is_static = false,
            .depth = 0,
        };
    }

    pub fn getCaller(self: InputsImpl) primitives.Address {
        return self.caller;
    }

    pub fn getTarget(self: InputsImpl) primitives.Address {
        return self.target;
    }

    pub fn getValue(self: InputsImpl) primitives.U256 {
        return self.value;
    }

    pub fn getData(self: InputsImpl) primitives.Bytes {
        return self.data;
    }

    pub fn getGasLimit(self: InputsImpl) u64 {
        return self.gas_limit;
    }

    pub fn getScheme(self: InputsImpl) CallScheme {
        return self.scheme;
    }

    pub fn getIsStatic(self: InputsImpl) bool {
        return self.is_static;
    }

    pub fn getDepth(self: InputsImpl) usize {
        return self.depth;
    }
};

/// Return data buffer
pub const ReturnDataImpl = struct {
    data: primitives.Bytes,
    gas_used: u64,
    success: bool,

    pub fn new(data: primitives.Bytes, gas_used: u64, success: bool) ReturnDataImpl {
        return ReturnDataImpl{
            .data = data,
            .gas_used = gas_used,
            .success = success,
        };
    }

    pub fn default() ReturnDataImpl {
        return ReturnDataImpl{
            .data = &[_]u8{},
            .gas_used = 0,
            .success = false,
        };
    }

    pub fn getData(self: ReturnDataImpl) primitives.Bytes {
        return self.data;
    }

    pub fn getGasUsed(self: ReturnDataImpl) u64 {
        return self.gas_used;
    }

    pub fn getSuccess(self: ReturnDataImpl) bool {
        return self.success;
    }

    pub fn setData(self: *ReturnDataImpl, data: primitives.Bytes) void {
        self.data = data;
    }

    pub fn setGasUsed(self: *ReturnDataImpl, gas_used: u64) void {
        self.gas_used = gas_used;
    }

    pub fn setSuccess(self: *ReturnDataImpl, success: bool) void {
        self.success = success;
    }
};

/// Runtime flags controlling execution behavior
pub const RuntimeFlags = struct {
    is_static: bool,
    spec_id: primitives.SpecId,

    pub fn new(is_static: bool, spec_id: primitives.SpecId) RuntimeFlags {
        return RuntimeFlags{
            .is_static = is_static,
            .spec_id = spec_id,
        };
    }

    pub fn default() RuntimeFlags {
        return RuntimeFlags{
            .is_static = false,
            .spec_id = .prague,
        };
    }

    pub fn getIsStatic(self: RuntimeFlags) bool {
        return self.is_static;
    }

    pub fn getSpecId(self: RuntimeFlags) primitives.SpecId {
        return self.spec_id;
    }

    pub fn setIsStatic(self: *RuntimeFlags, is_static: bool) void {
        self.is_static = is_static;
    }

    pub fn setSpecId(self: *RuntimeFlags, spec_id: primitives.SpecId) void {
        self.spec_id = spec_id;
    }
};

/// Extended bytecode functionality
pub const ExtBytecode = struct {
    inner: bytecode.Bytecode,
    pc: usize,
    /// Whether execution is still running (false after halt/stop/return)
    continue_execution: bool,
    /// If true, deinit() will free the bytecode's heap allocations.
    /// CALL frames share bytecode with account state (DB) and must NOT free it.
    /// CREATE init-code frames and test frames own their bytecode.
    owns_bytecode: bool,

    /// Borrow semantics: bytecode is shared with account state, will NOT be freed on deinit.
    pub fn new(bytecode_data: bytecode.Bytecode) ExtBytecode {
        return ExtBytecode{
            .inner = bytecode_data,
            .pc = 0,
            .continue_execution = true,
            .owns_bytecode = false,
        };
    }

    /// Ownership semantics: bytecode is owned by this frame and freed on deinit.
    /// Use for CREATE init-code frames and test frames with locally-created bytecodes.
    pub fn newOwned(bytecode_data: bytecode.Bytecode) ExtBytecode {
        return ExtBytecode{
            .inner = bytecode_data,
            .pc = 0,
            .continue_execution = true,
            .owns_bytecode = true,
        };
    }

    pub fn default() ExtBytecode {
        return ExtBytecode{
            .inner = bytecode.Bytecode.new(),
            .pc = 0,
            .continue_execution = true,
            .owns_bytecode = false,
        };
    }

    pub fn deinit(self: *ExtBytecode) void {
        if (self.owns_bytecode) {
            self.inner.deinit();
        }
    }

    /// Read current opcode byte (returns 0x00/STOP if past end)
    pub fn opcode(self: *const ExtBytecode) u8 {
        const b = self.inner.bytes();
        if (self.pc >= b.len) return 0x00;
        return b[self.pc];
    }

    /// Advance PC by delta bytes
    pub fn relativeJump(self: *ExtBytecode, delta: usize) void {
        self.pc += delta;
    }

    /// Set PC to absolute destination
    pub fn absoluteJump(self: *ExtBytecode, dest: usize) void {
        self.pc = dest;
    }

    /// Check if jump destination is a valid JUMPDEST
    pub fn isValidJump(self: *const ExtBytecode, dest: usize) bool {
        return self.inner.isValidJump(dest);
    }

    /// Read a single immediate byte at current PC (returns 0 if past end of code)
    pub fn readImmediate(self: *const ExtBytecode) u8 {
        const b = self.inner.bytes();
        if (self.pc >= b.len) return 0;
        return b[self.pc];
    }

    pub fn isNotEnd(self: *const ExtBytecode) bool {
        return self.continue_execution;
    }

    pub fn getBytecode(self: ExtBytecode) bytecode.Bytecode {
        return self.inner;
    }

    pub fn setBytecode(self: *ExtBytecode, bytecode_data: bytecode.Bytecode) void {
        self.inner = bytecode_data;
    }

    pub fn bytes(self: *const ExtBytecode) []const u8 {
        return self.inner.bytes();
    }
};

// ---------------------------------------------------------------------------
// Dispatch table types
// ---------------------------------------------------------------------------

/// Function pointer type for opcode handlers (re-exported from instruction_context.zig).
pub const InstructionFn = @import("instruction_context.zig").InstructionFn;

/// One entry in the dispatch table: a handler function and its static gas cost.
pub const InstructionEntry = struct {
    func: InstructionFn,
    static_gas: u64,

    pub fn unknown() InstructionEntry {
        return .{ .func = opUnknown, .static_gas = 0 };
    }
};

/// 256-entry dispatch table indexed by opcode byte.
pub const InstructionTable = [256]InstructionEntry;

/// Handler for unknown/disabled opcodes.
fn opUnknown(ctx: *InstructionContext) void {
    ctx.interpreter.halt(.invalid_opcode);
}

// ---------------------------------------------------------------------------
// Pending sub-call suspension types
// ---------------------------------------------------------------------------

/// Data stored when a CALL/CALLCODE/DELEGATECALL/STATICCALL suspends the interpreter.
pub const PendingCallData = struct {
    inputs: HostCallInputs,
    code: bytecode.Bytecode,
    checkpoint: JournalCheckpoint,
    ret_off: usize,
    ret_size: usize,
    /// EIP-8037 (Amsterdam+): state gas charged for a new account created by a
    /// value-bearing CALL. Refunded to the parent reservoir if the call fails
    /// (the account is not created), matching credit_state_gas_refund(NEW_ACCOUNT).
    new_account_state_gas: u64 = 0,
};

/// Data stored when a CREATE/CREATE2 suspends the interpreter.
pub const PendingCreateData = struct {
    inputs: CreateInputs,
    new_addr: primitives.Address,
    checkpoint: JournalCheckpoint,
    /// EIP-8037 (Amsterdam+): state gas charged for new account creation.
    /// On child CREATE halt/invalid, this is returned to the parent's reservoir.
    new_account_state_gas: u64 = 0,
    /// EIP-8037 (Amsterdam+): the CREATE target address was already alive (pre-funded
    /// balance) before creation. On success the NEW_ACCOUNT state gas is refunded,
    /// mirroring the reference `credit_state_gas_refund` when `target_alive`.
    target_alive: bool = false,
};

/// Pending sub-call state: set by CALL/CREATE opcodes, cleared by frame runner.
pub const PendingSubCall = union(enum) {
    none,
    call: PendingCallData,
    create: PendingCreateData,
};

// ---------------------------------------------------------------------------
// Main interpreter
// ---------------------------------------------------------------------------

/// Main interpreter structure that contains all components
pub const Interpreter = struct {
    bytecode: ExtBytecode,
    gas: Gas,
    stack: Stack,
    return_data: ReturnDataImpl,
    memory: Memory,
    input: InputsImpl,
    runtime_flags: RuntimeFlags,
    /// Execution result (set by halt())
    result: InstructionResult,
    extend: void,
    last_opcode: ?u8 = null,
    /// Pending sub-call: set by CALL/CREATE opcodes, cleared by frame runner.
    pending: PendingSubCall = .none,

    pub fn new(
        memory: Memory,
        bytecode_data: ExtBytecode,
        input: InputsImpl,
        is_static: bool,
        spec_id: primitives.SpecId,
        gas_limit: u64,
    ) Interpreter {
        return Interpreter{
            .bytecode = bytecode_data,
            .gas = Gas.new(gas_limit),
            .stack = Stack.new(),
            .return_data = ReturnDataImpl.default(),
            .memory = memory,
            .input = input,
            .runtime_flags = RuntimeFlags.new(is_static, spec_id),
            .result = .stop,
            .extend = {},
        };
    }

    pub fn defaultExt() Interpreter {
        return Interpreter.new(
            Memory.new(),
            ExtBytecode.default(),
            InputsImpl.default(),
            false,
            .prague,
            std.math.maxInt(u64),
        );
    }

    pub fn invalid() Interpreter {
        return Interpreter.new(
            Memory.new(),
            ExtBytecode.default(),
            InputsImpl.default(),
            false,
            .prague,
            0,
        );
    }

    /// Halt execution with the given result
    pub fn halt(self: *Interpreter, r: InstructionResult) void {
        self.bytecode.continue_execution = false;
        self.result = r;
        // EVM spec: all remaining gas is consumed on any error (OOG, invalid opcode, etc.).
        // Revert and success are NOT errors — they preserve remaining gas for refund/return.
        if (r.isError()) {
            self.gas.remaining = 0;
        }
    }

    pub fn deinit(self: *Interpreter) void {
        self.stack.deinit();
        self.bytecode.deinit();
        self.memory.deinit();
    }

    pub fn clear(
        self: *Interpreter,
        memory: Memory,
        bytecode_data: ExtBytecode,
        input: InputsImpl,
        is_static: bool,
        spec_id: primitives.SpecId,
        gas_limit: u64,
    ) void {
        self.bytecode = bytecode_data;
        self.gas = Gas.new(gas_limit);
        self.stack.clear();
        self.return_data = ReturnDataImpl.default();
        self.memory = memory;
        self.input = input;
        self.runtime_flags = RuntimeFlags.new(is_static, spec_id);
        self.result = .stop;
        self.extend = {};
        self.pending = .none;
    }

    // -----------------------------------------------------------------------
    // Dispatch methods
    // -----------------------------------------------------------------------

    /// Execute one opcode: read opcode at PC, advance PC, charge static gas, call handler.
    pub fn step(self: *Interpreter, table: *const InstructionTable) void {
        const op = self.bytecode.opcode();
        self.bytecode.relativeJump(1);
        const ins = table[op];
        if (!self.gas.spend(ins.static_gas)) {
            self.halt(.out_of_gas);
            return;
        }
        var ctx = InstructionContext{ .interpreter = self };
        ins.func(&ctx);
    }

    /// Run the interpreter until execution halts (no host).
    pub fn run(self: *Interpreter, table: *const InstructionTable) InstructionResult {
        var ctx = InstructionContext{ .interpreter = self };
        runDispatch(self, table, &ctx, false);
        return self.result;
    }

    /// Execute one opcode with a host for state access.
    pub fn stepWithHost(self: *Interpreter, table: *const InstructionTable, host: *Host) void {
        const op = self.bytecode.opcode();
        self.bytecode.relativeJump(1);
        const ins = table[op];
        if (!self.gas.spend(ins.static_gas)) {
            self.halt(.out_of_gas);
            return;
        }
        var ctx = InstructionContext{ .interpreter = self, .host = host };
        ins.func(&ctx);
    }

    /// Run the interpreter until execution halts or a sub-call is pending, with full host access.
    pub fn runWithHost(self: *Interpreter, table: *const InstructionTable, host: *Host) InstructionResult {
        var ctx = InstructionContext{ .interpreter = self, .host = host };
        runDispatch(self, table, &ctx, true);
        return self.result;
    }

    /// Reset this interpreter for a new frame without freeing the memory buffer.
    /// The memory buffer grows to its high-water mark and is reused across frames.
    pub fn clearReusingMemory(
        self: *Interpreter,
        bytecode_data: ExtBytecode,
        input: InputsImpl,
        is_static: bool,
        spec_id: primitives.SpecId,
        gas_limit: u64,
    ) void {
        self.memory.clear();
        self.clear(self.memory, bytecode_data, input, is_static, spec_id, gas_limit);
    }
};

// ---------------------------------------------------------------------------
// Labeled-switch computed-goto dispatch (Tier 1 hot path)
// ---------------------------------------------------------------------------
//
// Hot opcodes are inlined directly in switch cases — no per-opcode function
// call or InstructionContext construction. `continue :sw` compiles to a
// computed goto (single indirect branch). ctx is built once per runWithHost
// call and lives in registers across iterations.
//
// comptime check_pending=false (run):         pending check is folded away.
// comptime check_pending=true  (runWithHost): checks after every op.
//
// Cold opcodes fall to `else` which calls through InstructionTable as before.
//
// INVARIANT: only add opcodes here that are:
//   1. Valid since Frontier (no fork gate needed), AND
//   2. Behavior-stable across all forks (no semantic changes per EIP).
// Fork-*modified* opcodes (e.g. SELFDESTRUCT post-EIP-6780) must stay in the
// cold `else` path where the InstructionTable enforces the correct per-fork
// handler — a single flag cannot express "different handler per fork".
//
// A fork-*gated* opcode — one that is either the same handler or invalid, never
// a different handler — is admissible under a narrow exception: hoist the fork
// test out of the loop into a `const` below and guard the case with it, falling
// through to `else` when the gate is closed so the table still supplies
// opUnknown. This is sound because the spec is fixed for the lifetime of a
// frame. It is worth doing only for opcodes hot enough that a register-resident
// branch beats a table load plus an indirect call; SHL/SHR/SAR qualified on the
// Amsterdam benchmark tiers, where they measured 3,500-4,810 cost-per-gas
// against a median of 1,962 with ~80% of it in dispatch rather than the shift.
// PUSH0 and the rest stay cold.

const U = primitives.U256;

/// Per-frame constants the threaded handlers read through one pointer.
const Frame = struct {
    self: *Interpreter,
    /// The zero-padded code the handlers fetch from; `ip - base` is the pc.
    base: [*]const u8,
    /// Stack base; the backing store is fixed for the frame.
    sb: [*]U,
    /// JUMPDEST bitmap, one bit per code byte; empty for a delegation designator.
    jbits: [*]const u8,
    jlen: usize,
    code_len: usize,
    /// Block and transaction context; null when running without a host.
    host: ?*Host,
};

/// Interpreter state the handlers pass each other in registers. `self.gas.remaining`,
/// `self.stack.length` and `self.bytecode.pc` are stale until a handler hands an op
/// back to runDispatch and `spill`s them.
const Regs = struct {
    ip: [*]const u8,
    gas: u64,
    /// One past the top of the stack: `sb + sp`.
    top: [*]U,
    /// Stack length.
    sp: usize,
};

/// One handler per (opcode, next byte): the table is indexed by the two bytes at the
/// instruction pointer, so a hot pair runs as one handler. Every handler ends in a tail
/// call to the next one, or returns to runDispatch with an op it does not run itself.
const Handler = *const fn (fr: *const Frame, ip: [*]const u8, gas: u64, top: [*]U, sp: usize, tbl: *const anyopaque) callconv(.c) void;

inline fn spill(fr: *const Frame, r: *const Regs) void {
    const self = fr.self;
    self.bytecode.pc = @intFromPtr(r.ip) - @intFromPtr(fr.base);
    self.gas.remaining = r.gas;
    self.stack.length = r.sp;
}

inline fn push(r: *Regs, v: U) void {
    r.top[0] = v;
    r.top += 1;
    r.sp += 1;
}

const ops = struct {
    fn add(a: primitives.U256, b: primitives.U256) primitives.U256 {
        return a +% b;
    }
    fn sub(a: primitives.U256, b: primitives.U256) primitives.U256 {
        return a -% b;
    }
    fn mul(a: primitives.U256, b: primitives.U256) primitives.U256 {
        return a *% b;
    }
    fn lt(a: primitives.U256, b: primitives.U256) primitives.U256 {
        return @intFromBool(a < b);
    }
    fn gt(a: primitives.U256, b: primitives.U256) primitives.U256 {
        return @intFromBool(a > b);
    }
    fn eq(a: primitives.U256, b: primitives.U256) primitives.U256 {
        return @intFromBool(a == b);
    }
    fn band(a: primitives.U256, b: primitives.U256) primitives.U256 {
        return a & b;
    }
    fn bor(a: primitives.U256, b: primitives.U256) primitives.U256 {
        return a | b;
    }
    fn bxor(a: primitives.U256, b: primitives.U256) primitives.U256 {
        return a ^ b;
    }
    fn shl(shift: primitives.U256, value: primitives.U256) primitives.U256 {
        return if (shift < 256) value << @intCast(shift) else 0;
    }
    fn shr(shift: primitives.U256, value: primitives.U256) primitives.U256 {
        return if (shift < 256) value >> @intCast(shift) else 0;
    }
    fn slt(a: primitives.U256, b: primitives.U256) primitives.U256 {
        return @intFromBool(@as(i256, @bitCast(a)) < @as(i256, @bitCast(b)));
    }
    fn sgt(a: primitives.U256, b: primitives.U256) primitives.U256 {
        return @intFromBool(@as(i256, @bitCast(a)) > @as(i256, @bitCast(b)));
    }
    fn byte(i: primitives.U256, x: primitives.U256) primitives.U256 {
        return if (i < 32) (x >> @intCast((31 - i) * 8)) & 0xFF else 0;
    }
    fn iszero(a: primitives.U256) primitives.U256 {
        return @intFromBool(a == 0);
    }
    fn not(a: primitives.U256) primitives.U256 {
        return ~a;
    }
};

/// A 32-byte word at `offset` lies inside the current memory (no expansion needed).
inline fn inMemory(self: *Interpreter, offset: primitives.U256) bool {
    const size = self.memory.size();
    return size >= 32 and offset <= size - 32;
}

/// Validate a jump destination popped from the stack.
inline fn jumpTarget(self: *Interpreter, dest: primitives.U256) ?usize {
    if (dest > std.math.maxInt(usize)) return null;
    const d: usize = @intCast(dest);
    if (!self.bytecode.isValidJump(d)) return null;
    return d;
}

fn runDispatch(
    self: *Interpreter,
    table: *const InstructionTable,
    ctx: *InstructionContext,
    comptime check_pending: bool,
) void {
    if (!self.bytecode.isNotEnd()) return;
    // Fetch from the zero-padded copy, so neither opcode fetch nor PUSH immediates
    // check bounds: running off the end reads STOP. CODESIZE uses the real length.
    // A delegation designator is executable too (a delegation that points at a
    // delegated account runs the target's 0xef01.. bytes, and halts on 0xef); its
    // 23 bytes are padded here, on the stack, for the length of this call.
    var designator: [23 + bytecode.EXEC_PAD]u8 = undefined;
    var jbits: [*]const u8 = &.{};
    var jlen: usize = 0;
    const code: []const u8 = switch (self.bytecode.inner) {
        .legacy_analyzed => |*a| blk: {
            jbits = a.jump_table.data.ptr;
            jlen = a.jump_table.bit_len;
            break :blk a.exec;
        },
        .eip7702 => |*d| blk: {
            @memset(&designator, bytecode.STOP);
            @memcpy(designator[0..23], &d.raw_bytes);
            break :blk &designator;
        },
    };
    const fr = Frame{
        .self = self,
        .base = code.ptr,
        .sb = self.stack.data.ptr,
        .jbits = jbits,
        .jlen = jlen,
        .code_len = self.bytecode.bytes().len,
        .host = ctx.host,
    };
    // Osaka and later open every fork gate the fast path knows (EIP-145, EIP-211,
    // EIP-3855, EIP-7939); earlier forks hand the gated ops to the table below.
    const t: *const [65536]Handler = if (primitives.isEnabledIn(self.runtime_flags.spec_id, .osaka)) &modern_table else &legacy_table;
    while (true) {
        // The handlers run until an op they do not run themselves: a cold or gated op,
        // a halt, or any check that fails. They leave pc at that op.
        const ip = code.ptr + self.bytecode.pc;
        const h = t[key(ip)];
        // Straight to the table when the chain would hand the op back at once.
        if (h != &exit) h(&fr, ip, self.gas.remaining, fr.sb + self.stack.length, self.stack.length, @ptrCast(t));
        // Run that op through the instruction table, as `step` does.
        const op = code[self.bytecode.pc];
        self.bytecode.pc += 1;
        const entry = table[op];
        if (!self.gas.spend(entry.static_gas)) return self.halt(.out_of_gas);
        entry.func(ctx);
        if (!self.bytecode.isNotEnd()) return;
        // Only the CALL/CREATE family suspends the frame.
        if (check_pending and self.pending != .none) return;
    }
}

/// The two bytes at `ip`, opcode in the low byte.
inline fn key(ip: [*]const u8) u16 {
    return std.mem.readInt(u16, ip[0..2], .little);
}

inline fn next(fr: *const Frame, r: Regs, tbl: *const anyopaque) void {
    const t: *const [65536]Handler = @ptrCast(@alignCast(tbl));
    return @call(.always_tail, t[key(r.ip)], .{ fr, r.ip, r.gas, r.top, r.sp, tbl });
}

/// `body`: done, jumped (the next op is elsewhere), or declined with `r` untouched.
const Flow = enum { next, jumped, slow };

fn binFn(comptime op: u8) fn (U, U) U {
    return switch (op) {
        0x01 => ops.add,
        0x02 => ops.mul,
        0x03 => ops.sub,
        0x10 => ops.lt,
        0x11 => ops.gt,
        0x12 => ops.slt,
        0x13 => ops.sgt,
        0x14 => ops.eq,
        0x16 => ops.band,
        0x17 => ops.bor,
        0x18 => ops.bxor,
        0x1A => ops.byte,
        0x1B => ops.shl,
        0x1C => ops.shr,
        0x1D => sar,
        else => unreachable,
    };
}

fn sar(shift: U, value: U) U {
    const v: i256 = @bitCast(value);
    if (shift >= 256) return if (v < 0) ~@as(U, 0) else 0;
    return @bitCast(v >> @intCast(shift));
}

/// A valid JUMPDEST.
inline fn validJump(fr: *const Frame, dest: U) ?usize {
    if (dest >= fr.jlen) return null;
    const d: usize = @intCast(dest);
    if ((fr.jbits[d >> 3] >> @intCast(d & 7)) & 1 == 0) return null;
    return d;
}

/// Static checks for `op` (skipped when a fused pair checked them together).
inline fn ok(comptime op: u8, comptime ck: bool, r: *const Regs) bool {
    if (!ck) return true;
    const m = comptime model(op).?;
    if (r.gas < m.gas or r.sp < m.pops) return false;
    if (m.pushes > m.pops and r.sp > stack_mod.STACK_LIMIT - (m.pushes - m.pops)) return false;
    return true;
}

/// The hot path of one opcode: no calls, and nothing that can halt. Anything off the
/// fast path (out of gas, stack bounds, a bad jump, memory growth) returns `.slow`
/// before touching `r`, and runDispatch runs the op through the instruction table.
/// With `ck == false` the caller has checked `model(op)` already.
inline fn body(comptime op: u8, comptime ck: bool, fr: *const Frame, r: *Regs) Flow {
    const self = fr.self;
    const m = comptime model(op).?;
    if (!ok(op, ck, r)) return .slow;
    switch (op) {
        0x01, 0x02, 0x03, 0x10, 0x11, 0x12, 0x13, 0x14, 0x16, 0x17, 0x18, 0x1A, 0x1B, 0x1C, 0x1D => {
            const a = (r.top - 1)[0];
            const b = (r.top - 2)[0];
            r.top -= 1;
            r.sp -= 1;
            (r.top - 1)[0] = binFn(op)(a, b);
        },
        0x15 => (r.top - 1)[0] = ops.iszero((r.top - 1)[0]),
        0x19 => (r.top - 1)[0] = ops.not((r.top - 1)[0]),
        0x1E => (r.top - 1)[0] = @clz((r.top - 1)[0]), // CLZ (EIP-7939): 256 for zero
        0x35 => { // CALLDATALOAD: whole word in range, or wholly past the end
            const offset = (r.top - 1)[0];
            const data = self.input.data;
            if (offset >= data.len) {
                (r.top - 1)[0] = 0;
            } else {
                const off: usize = @intCast(offset);
                if (data.len - off < 32) return .slow;
                (r.top - 1)[0] = std.mem.readInt(U, data[off..][0..32], .big);
            }
        },
        0x50 => { // POP
            r.top -= 1;
            r.sp -= 1;
        },
        // MLOAD/MSTORE stay here when the word is already inside memory (no expansion,
        // so no gas beyond the static G_VERYLOW).
        0x51 => { // MLOAD
            if (!inMemory(self, (r.top - 1)[0])) return .slow;
            const off: usize = @intCast((r.top - 1)[0]);
            (r.top - 1)[0] = std.mem.readInt(U, self.memory.buffer.items[off..][0..32], .big);
        },
        0x52 => { // MSTORE
            if (!inMemory(self, (r.top - 1)[0])) return .slow;
            const off: usize = @intCast((r.top - 1)[0]);
            std.mem.writeInt(U, self.memory.buffer.items[off..][0..32], (r.top - 2)[0], .big);
            r.top -= 2;
            r.sp -= 2;
        },
        // JUMP lands one past the JUMPDEST and charges its gas here, so a taken jump
        // never dispatches the JUMPDEST. Same outcome as running it: JUMPDEST costs
        // G_JUMPDEST and does nothing else.
        0x56 => { // JUMP
            const d = validJump(fr, (r.top - 1)[0]) orelse return .slow;
            if (r.gas < m.gas + gas_costs.G_JUMPDEST) return .slow;
            r.gas -= m.gas + gas_costs.G_JUMPDEST;
            r.top -= 1;
            r.sp -= 1;
            r.ip = fr.base + d + 1;
            return .jumped;
        },
        0x57 => { // JUMPI
            if ((r.top - 2)[0] != 0) {
                const d = validJump(fr, (r.top - 1)[0]) orelse return .slow;
                if (r.gas < m.gas + gas_costs.G_JUMPDEST) return .slow;
                r.gas -= m.gas + gas_costs.G_JUMPDEST;
                r.top -= 2;
                r.sp -= 2;
                r.ip = fr.base + d + 1;
                return .jumped;
            }
            r.top -= 2;
            r.sp -= 2;
        },
        0x5B => {}, // JUMPDEST (reached by falling through, not by a jump)
        0x60...0x7F => { // PUSH1..PUSH32: immediates read straight from the code
            const n = op - 0x60 + 1;
            var buf: [32]u8 = .{0} ** 32;
            @memcpy(buf[32 - n ..], r.ip[1..][0..n]);
            push(r, (@as(U, std.mem.readInt(u64, buf[0..8], .big)) << 192) |
                (@as(U, std.mem.readInt(u64, buf[8..16], .big)) << 128) |
                (@as(U, std.mem.readInt(u64, buf[16..24], .big)) << 64) |
                @as(U, std.mem.readInt(u64, buf[24..32], .big)));
            r.ip += n;
        },
        0x80...0x8F => push(r, (r.top - (op - 0x80 + 1))[0]), // DUP1..DUP16
        0x90...0x9F => { // SWAP1..SWAP16
            const n = op - 0x90 + 1;
            const t = (r.top - 1)[0];
            (r.top - 1)[0] = (r.top - 1 - n)[0];
            (r.top - 1 - n)[0] = t;
        },
        0x5A => push(r, r.gas - m.gas), // GAS: the gas left after its own charge
        0x3D => push(r, self.return_data.data.len), // RETURNDATASIZE (gate open)
        0x5F => push(r, 0), // PUSH0 (gate open)
        // ADDRESS, CALLER, CALLVALUE, CALLDATASIZE, CODESIZE, PC, MSIZE
        0x30 => push(r, host_mod.addressToU256(self.input.target)),
        0x33 => push(r, host_mod.addressToU256(self.input.caller)),
        0x34 => push(r, self.input.value),
        0x36 => push(r, self.input.data.len),
        0x38 => push(r, fr.code_len),
        0x58 => push(r, @intFromPtr(r.ip) - @intFromPtr(fr.base)),
        0x59 => push(r, self.memory.size()),
        // Block and transaction context (needs a host; gated ops in the modern table).
        0x32 => push(r, host_mod.addressToU256((fr.host orelse return .slow).origin())),
        0x3A => push(r, (fr.host orelse return .slow).gasPrice()),
        0x41 => push(r, host_mod.addressToU256((fr.host orelse return .slow).coinbase())),
        0x42 => push(r, (fr.host orelse return .slow).timestamp()),
        0x43 => push(r, (fr.host orelse return .slow).blockNumber()),
        0x45 => push(r, (fr.host orelse return .slow).blockGasLimit()),
        0x46 => push(r, (fr.host orelse return .slow).chainId()),
        0x48 => push(r, (fr.host orelse return .slow).basefee()),
        0x4A => push(r, (fr.host orelse return .slow).blobBasefee()),
        0x49 => { // BLOBHASH
            const h = fr.host orelse return .slow;
            const idx = (r.top - 1)[0];
            (r.top - 1)[0] = if (idx > std.math.maxInt(usize)) 0 else (h.blobHash(@intCast(idx)) orelse 0);
        },
        else => return .slow,
    }
    r.gas -= m.gas;
    r.ip += 1;
    return .next;
}

/// Static cost and stack shape of an op the fast path runs: it needs `pops` items
/// and leaves `pushes` in their place.
const Model = struct { gas: u64, pops: usize, pushes: usize };

fn model(comptime op: u8) ?Model {
    const VL = gas_costs.G_VERYLOW;
    const B = gas_costs.G_BASE;
    return switch (op) {
        0x01, 0x03, 0x10, 0x11, 0x12, 0x13, 0x14, 0x16, 0x17, 0x18, 0x1A, 0x1B, 0x1C, 0x1D => .{ .gas = VL, .pops = 2, .pushes = 1 },
        0x02 => .{ .gas = gas_costs.G_LOW, .pops = 2, .pushes = 1 },
        0x1E => .{ .gas = gas_costs.G_LOW, .pops = 1, .pushes = 1 },
        0x15, 0x19, 0x35, 0x51 => .{ .gas = VL, .pops = 1, .pushes = 1 },
        0x52 => .{ .gas = VL, .pops = 2, .pushes = 0 },
        0x50 => .{ .gas = B, .pops = 1, .pushes = 0 },
        0x56 => .{ .gas = gas_costs.G_MID, .pops = 1, .pushes = 0 },
        0x57 => .{ .gas = gas_costs.G_HIGH, .pops = 2, .pushes = 0 },
        0x5B => .{ .gas = gas_costs.G_JUMPDEST, .pops = 0, .pushes = 0 },
        0x60...0x7F => .{ .gas = VL, .pops = 0, .pushes = 1 },
        0x80...0x8F => .{ .gas = VL, .pops = op - 0x80 + 1, .pushes = op - 0x80 + 2 },
        0x90...0x9F => .{ .gas = VL, .pops = op - 0x90 + 2, .pushes = op - 0x90 + 2 },
        0x30, 0x33, 0x34, 0x36, 0x38, 0x3D, 0x58, 0x59, 0x5A, 0x5F => .{ .gas = B, .pops = 0, .pushes = 1 },
        0x32, 0x3A, 0x41, 0x42, 0x43, 0x45, 0x46, 0x48, 0x4A => .{ .gas = B, .pops = 0, .pushes = 1 },
        0x49 => .{ .gas = VL, .pops = 1, .pushes = 1 },
        else => null,
    };
}

/// Ops whose fork gate the modern table assumes open.
fn gated(op: u8) bool {
    return switch (op) {
        0x1B, 0x1C, 0x1D, 0x1E, 0x3D, 0x5F, 0x46, 0x48, 0x49, 0x4A => true,
        else => false,
    };
}

/// Hands the op at `ip` back to runDispatch.
fn exit(fr: *const Frame, ip: [*]const u8, gas: u64, top: [*]U, sp: usize, tbl: *const anyopaque) callconv(.c) void {
    _ = top;
    _ = tbl;
    spill(fr, &.{ .ip = ip, .gas = gas, .top = undefined, .sp = sp });
}

/// Ops a PUSH runs inline when they follow its immediate (the two-byte key cannot see
/// them: its second byte is the immediate). Picked from mainnet follower counts.
fn pushFollowers(comptime op: u8) []const u8 {
    return switch (op) {
        0x60 => &.{}, // PUSH1: followers too spread out to pay for the check
        0x63 => &.{ 0x14, 0x11 }, // PUSH4: EQ, GT (selector matching)
        0x73 => &.{0x16}, // PUSH20: AND
        0x61 => &.{ 0x57, 0x56 }, // PUSH2: JUMPI, JUMP
        else => &.{},
    };
}

/// PUSHn dest; JUMP / JUMPI without putting dest on the stack. False (nothing changed)
/// when anything is off; the caller then runs the PUSH alone.
inline fn pushJump(comptime op: u8, comptime f: u8, fr: *const Frame, r: *Regs) bool {
    const n = op - 0x5f;
    if (r.sp >= stack_mod.STACK_LIMIT) return false; // the PUSH itself would overflow
    var buf: [32]u8 = .{0} ** 32;
    @memcpy(buf[32 - n ..], r.ip[1..][0..n]);
    const dest = std.mem.readInt(U, &buf, .big);
    const VL = gas_costs.G_VERYLOW;
    if (f == 0x56) {
        const cost = VL + gas_costs.G_MID + gas_costs.G_JUMPDEST;
        if (r.gas < cost) return false;
        const d = validJump(fr, dest) orelse return false;
        r.gas -= cost;
        r.ip = fr.base + d + 1;
        return true;
    }
    if (r.sp < 1) return false;
    if ((r.top - 1)[0] != 0) {
        const cost = VL + gas_costs.G_HIGH + gas_costs.G_JUMPDEST;
        if (r.gas < cost) return false;
        const d = validJump(fr, dest) orelse return false;
        r.gas -= cost;
        r.ip = fr.base + d + 1;
    } else {
        const cost = VL + gas_costs.G_HIGH;
        if (r.gas < cost) return false;
        r.gas -= cost;
        r.ip += n + 2;
    }
    r.top -= 1;
    r.sp -= 1;
    return true;
}

fn pushHandler(comptime op: u8) Handler {
    const n = op - 0x5f;
    return &struct {
        fn h(fr: *const Frame, ip: [*]const u8, gas: u64, top: [*]U, sp: usize, tbl: *const anyopaque) callconv(.c) void {
            var r = Regs{ .ip = ip, .gas = gas, .top = top, .sp = sp };
            const b = ip[1 + n];
            inline for (comptime pushFollowers(op)) |f| {
                if (b == f) {
                    if (f == 0x56 or f == 0x57) {
                        if (pushJump(op, f, fr, &r)) return next(fr, r, tbl);
                    } else {
                        return @call(.always_tail, fused(op, f), .{ fr, ip, gas, top, sp, tbl });
                    }
                }
            }
            if (body(op, true, fr, &r) == .slow) return spill(fr, &r);
            return next(fr, r, tbl);
        }
    }.h;
}

fn single(comptime op: u8) Handler {
    if (op >= 0x60 and op <= 0x7F) return pushHandler(op);
    return plain(op);
}

/// One op, no lookahead (also the fused-pair fallback, so a PUSH pair cannot loop).
fn plain(comptime op: u8) Handler {
    return &struct {
        fn h(fr: *const Frame, ip: [*]const u8, gas: u64, top: [*]U, sp: usize, tbl: *const anyopaque) callconv(.c) void {
            var r = Regs{ .ip = ip, .gas = gas, .top = top, .sp = sp };
            if (body(op, true, fr, &r) == .slow) return spill(fr, &r);
            return next(fr, r, tbl);
        }
    }.h;
}

/// `a` then `b` behind one gas check and one stack check. When the combined check
/// fails, run `a` alone and dispatch `b` normally: exact either way.
fn fused(comptime a: u8, comptime b: u8) Handler {
    const ma = comptime model(a).?;
    const mb = comptime model(b).?;
    const gas = ma.gas + mb.gas;
    const pa: i64 = ma.pops;
    const ua: i64 = ma.pushes;
    const pb: i64 = mb.pops;
    const ub: i64 = mb.pushes;
    // Items needed before `a` so that `a` and then `b` both find theirs.
    const lo: usize = @intCast(@max(pa, pb + pa - ua, 0));
    // Largest growth over the pair; each push needs room for it.
    const grow: usize = @intCast(@max(ua - pa, ua - pa + ub - pb, 0));
    const hi: usize = stack_mod.STACK_LIMIT - grow;
    return &struct {
        fn h(fr: *const Frame, ip: [*]const u8, g: u64, top: [*]U, sp: usize, tbl: *const anyopaque) callconv(.c) void {
            if (g < gas or sp < lo or sp > hi)
                return @call(.always_tail, plain(a), .{ fr, ip, g, top, sp, tbl });
            var r = Regs{ .ip = ip, .gas = g, .top = top, .sp = sp };
            switch (body(a, false, fr, &r)) {
                .slow => return spill(fr, &r),
                .jumped => return next(fr, r, tbl),
                .next => {},
            }
            if (body(b, false, fr, &r) == .slow) return spill(fr, &r);
            return next(fr, r, tbl);
        }
    }.h;
}

/// Pairs run as one handler: the most frequent adjacent pairs on mainnet and Sepolia
/// blocks whose ops both have a `model` (no PUSH first: the second byte is its immediate).
const fused_pairs = [_][2]u8{
    .{ 0x50, 0x60 }, // POP PUSH1
    .{ 0x01, 0x61 }, // ADD PUSH2
    .{ 0x57, 0x60 }, // JUMPI PUSH1
    .{ 0x10, 0x60 }, // LT PUSH1
    .{ 0x5A, 0x10 }, // GAS LT
    .{ 0x50, 0x50 }, // POP POP
    .{ 0x15, 0x61 }, // ISZERO PUSH2
    .{ 0x90, 0x50 }, // SWAP1 POP
    .{ 0x52, 0x60 }, // MSTORE PUSH1
    .{ 0x50, 0x56 }, // POP JUMP
    .{ 0x14, 0x61 }, // EQ PUSH2
    .{ 0x80, 0x63 }, // DUP1 PUSH4
    .{ 0x91, 0x50 }, // SWAP2 POP
    .{ 0x57, 0x80 }, // JUMPI DUP1
    .{ 0x91, 0x90 }, // SWAP2 SWAP1
    .{ 0x81, 0x52 }, // DUP2 MSTORE
    .{ 0x01, 0x90 }, // ADD SWAP1
    .{ 0x81, 0x10 }, // DUP2 LT
    .{ 0x10, 0x15 }, // LT ISZERO
    .{ 0x90, 0x61 }, // SWAP1 PUSH2
    .{ 0x92, 0x91 }, // SWAP3 SWAP2
    .{ 0x82, 0x01 }, // DUP3 ADD
    .{ 0x1B, 0x03 }, // SHL SUB
    .{ 0x90, 0x56 }, // SWAP1 JUMP
    .{ 0x90, 0x81 }, // SWAP1 DUP2
    .{ 0x50, 0x61 }, // POP PUSH2
    .{ 0x81, 0x01 }, // DUP2 ADD
    .{ 0x10, 0x61 }, // LT PUSH2
    .{ 0x01, 0x52 }, // ADD MSTORE
    .{ 0x81, 0x81 }, // DUP2 DUP2
    .{ 0x92, 0x50 }, // SWAP3 POP
    .{ 0x01, 0x51 }, // ADD MLOAD
    .{ 0x15, 0x15 }, // ISZERO ISZERO
    .{ 0x90, 0x91 }, // SWAP1 SWAP2
    .{ 0x51, 0x60 }, // MLOAD PUSH1
    .{ 0x80, 0x82 }, // DUP1 DUP3
    .{ 0x11, 0x15 }, // GT ISZERO
    .{ 0x16, 0x60 }, // AND PUSH1
    .{ 0x90, 0x60 }, // SWAP1 PUSH1
    .{ 0x82, 0x61 }, // DUP3 PUSH2
    .{ 0x16, 0x81 }, // AND DUP2
    .{ 0x51, 0x80 }, // MLOAD DUP1
    .{ 0x80, 0x60 }, // DUP1 PUSH1
    .{ 0x01, 0x60 }, // ADD PUSH1
    .{ 0x81, 0x61 }, // DUP2 PUSH2
    .{ 0x11, 0x61 }, // GT PUSH2
    .{ 0x50, 0x91 }, // POP SWAP2
    .{ 0x83, 0x01 }, // DUP4 ADD
    .{ 0x35, 0x60 }, // CDLOAD PUSH1
    .{ 0x16, 0x90 }, // AND SWAP1
    .{ 0x80, 0x15 }, // DUP1 ISZERO
    .{ 0x81, 0x90 }, // DUP2 SWAP1
    .{ 0x51, 0x90 }, // MLOAD SWAP1
    .{ 0x50, 0x92 }, // POP SWAP3
    .{ 0x03, 0x81 }, // SUB DUP2
    .{ 0x03, 0x90 }, // SUB SWAP1
    .{ 0x93, 0x92 }, // SWAP4 SWAP3
    .{ 0x82, 0x84 }, // DUP3 DUP5
    .{ 0x82, 0x82 }, // DUP3 DUP3
    .{ 0x01, 0x91 }, // ADD SWAP2
    .{ 0x83, 0x81 }, // DUP4 DUP2
    .{ 0x80, 0x51 }, // DUP1 MLOAD
    .{ 0x50, 0x90 }, // POP SWAP1
    .{ 0x82, 0x16 }, // DUP3 AND
    .{ 0x81, 0x14 }, // DUP2 EQ
    .{ 0x5F, 0x51 }, // PUSH0 MLOAD
    .{ 0x82, 0x11 }, // DUP3 GT
    .{ 0x91, 0x01 }, // SWAP2 ADD
    .{ 0x84, 0x01 }, // DUP5 ADD
    .{ 0x81, 0x16 }, // DUP2 AND
    .{ 0x01, 0x35 }, // ADD CDLOAD
    .{ 0x82, 0x81 }, // DUP3 DUP2
    .{ 0x51, 0x61 }, // MLOAD PUSH2
    .{ 0x50, 0x80 }, // POP DUP1
    .{ 0x83, 0x61 }, // DUP4 PUSH2
    .{ 0x82, 0x52 }, // DUP3 MSTORE
    .{ 0x5F, 0x61 }, // PUSH0 PUSH2
    .{ 0x81, 0x51 }, // DUP2 MLOAD
    .{ 0x80, 0x83 }, // DUP1 DUP4
    .{ 0x5F, 0x60 }, // PUSH0 PUSH1
    .{ 0x03, 0x16 }, // SUB AND
    .{ 0x03, 0x61 }, // SUB PUSH2
    .{ 0x16, 0x15 }, // AND ISZERO
    .{ 0x01, 0x01 }, // ADD ADD
    .{ 0x80, 0x61 }, // DUP1 PUSH2
    .{ 0x81, 0x11 }, // DUP2 GT
    .{ 0x81, 0x60 }, // DUP2 PUSH1
    .{ 0x16, 0x61 }, // AND PUSH2
    .{ 0x5F, 0x81 }, // PUSH0 DUP2
    .{ 0x36, 0x03 }, // CDSIZE SUB
    .{ 0x57, 0x61 }, // JUMPI PUSH2
    .{ 0x5F, 0x5F }, // PUSH0 PUSH0
    .{ 0x52, 0x50 }, // MSTORE POP
    .{ 0x01, 0x80 }, // ADD DUP1
    .{ 0x84, 0x61 }, // DUP5 PUSH2
    .{ 0x90, 0x03 }, // SWAP1 SUB
    .{ 0x51, 0x81 }, // MLOAD DUP2
    .{ 0x80, 0x91 }, // DUP1 SWAP2
    .{ 0x36, 0x10 }, // CDSIZE LT
    .{ 0x12, 0x15 }, // SLT ISZERO
    .{ 0x01, 0x81 }, // ADD DUP2
    .{ 0x91, 0x82 }, // SWAP2 DUP3
    .{ 0x12, 0x61 }, // SLT PUSH2
    .{ 0x84, 0x84 }, // DUP5 DUP5
    .{ 0x90, 0x52 }, // SWAP1 MSTORE
    .{ 0x85, 0x01 }, // DUP6 ADD
    .{ 0x83, 0x03 }, // DUP4 SUB
    .{ 0x81, 0x83 }, // DUP2 DUP4
    .{ 0x35, 0x90 }, // CDLOAD SWAP1
    .{ 0x80, 0x35 }, // DUP1 CDLOAD
    .{ 0x01, 0x92 }, // ADD SWAP3
    .{ 0x83, 0x83 }, // DUP4 DUP4
    .{ 0x16, 0x56 }, // AND JUMP
    .{ 0x81, 0x35 }, // DUP2 CDLOAD
    .{ 0x02, 0x60 }, // MUL PUSH1
    .{ 0x82, 0x60 }, // DUP3 PUSH1
    .{ 0x03, 0x12 }, // SUB SLT
    .{ 0x80, 0x80 }, // DUP1 DUP1
    .{ 0x93, 0x50 }, // SWAP4 POP
    .{ 0x90, 0x92 }, // SWAP1 SWAP3
    .{ 0x57, 0x50 }, // JUMPI POP
    .{ 0x5F, 0x52 }, // PUSH0 MSTORE
    .{ 0x1C, 0x80 }, // SHR DUP1
    .{ 0x50, 0x81 }, // POP DUP2
    .{ 0x16, 0x73 }, // AND PUSH20
    .{ 0x92, 0x90 }, // SWAP3 SWAP1
    .{ 0x03, 0x60 }, // SUB PUSH1
    .{ 0x03, 0x01 }, // SUB ADD
    .{ 0x50, 0x5B }, // POP JUMPDEST
    .{ 0x15, 0x80 }, // ISZERO DUP1
    .{ 0x83, 0x82 }, // DUP4 DUP3
    .{ 0x51, 0x91 }, // MLOAD SWAP2
    .{ 0x90, 0x5F }, // SWAP1 PUSH0
    .{ 0x83, 0x60 }, // DUP4 PUSH1
    .{ 0x85, 0x61 }, // DUP6 PUSH2
    .{ 0x52, 0x61 }, // MSTORE PUSH2
    .{ 0x02, 0x01 }, // MUL ADD
    .{ 0x86, 0x01 }, // DUP7 ADD
    .{ 0x03, 0x82 }, // SUB DUP3
    .{ 0x90, 0x63 }, // SWAP1 PUSH4
    .{ 0x82, 0x03 }, // DUP3 SUB
    .{ 0x82, 0x90 }, // DUP3 SWAP1
    .{ 0x84, 0x60 }, // DUP5 PUSH1
    .{ 0x52, 0x82 }, // MSTORE DUP3
    .{ 0x51, 0x83 }, // MLOAD DUP4
    .{ 0x82, 0x10 }, // DUP3 LT
    .{ 0x84, 0x03 }, // DUP5 SUB
    .{ 0x85, 0x85 }, // DUP6 DUP6
    .{ 0x57, 0x56 }, // JUMPI JUMP
    .{ 0x81, 0x15 }, // DUP2 ISZERO
    .{ 0x91, 0x03 }, // SWAP2 SUB
    .{ 0x16, 0x82 }, // AND DUP3
    .{ 0x52, 0x90 }, // MSTORE SWAP1
    .{ 0x81, 0x12 }, // DUP2 SLT
    .{ 0x14, 0x15 }, // EQ ISZERO
    .{ 0x36, 0x60 }, // CDSIZE PUSH1
    .{ 0x57, 0x81 }, // JUMPI DUP2
    .{ 0x3D, 0x60 }, // RDSIZE PUSH1
    .{ 0x5F, 0x83 }, // PUSH0 DUP4
    .{ 0x85, 0x81 }, // DUP6 DUP2
    .{ 0x83, 0x16 }, // DUP4 AND
    .{ 0x90, 0x83 }, // SWAP1 DUP4
    .{ 0x17, 0x61 }, // OR PUSH2
    .{ 0x90, 0x82 }, // SWAP1 DUP3
    .{ 0x02, 0x81 }, // MUL DUP2
    .{ 0x57, 0x5F }, // JUMPI PUSH0
    .{ 0x5B, 0x50 }, // JUMPDEST POP
    .{ 0x91, 0x60 }, // SWAP2 PUSH1
    .{ 0x01, 0x16 }, // ADD AND
    .{ 0x5F, 0x73 }, // PUSH0 PUSH20
    .{ 0x84, 0x81 }, // DUP5 DUP2
    .{ 0x52, 0x56 }, // MSTORE JUMP
    .{ 0x82, 0x35 }, // DUP3 CDLOAD
    .{ 0x80, 0x84 }, // DUP1 DUP5
    .{ 0x19, 0x16 }, // NOT AND
    .{ 0x57, 0x5B }, // JUMPI JUMPDEST
    .{ 0x5F, 0x82 }, // PUSH0 DUP3
    .{ 0x80, 0x36 }, // DUP1 CDSIZE
    .{ 0x35, 0x61 }, // CDLOAD PUSH2
    .{ 0x33, 0x73 }, // CALLER PUSH20
    .{ 0x91, 0x61 }, // SWAP2 PUSH2
    .{ 0x84, 0x16 }, // DUP5 AND
    .{ 0x34, 0x80 }, // CALLVALUE DUP1
    .{ 0x82, 0x02 }, // DUP3 MUL
    .{ 0x5F, 0x80 }, // PUSH0 DUP1
    .{ 0x01, 0x82 }, // ADD DUP3
    .{ 0x5B, 0x61 }, // JUMPDEST PUSH2
    .{ 0x52, 0x80 }, // MSTORE DUP1
    .{ 0x01, 0x93 }, // ADD SWAP4
    .{ 0x16, 0x80 }, // AND DUP1
    .{ 0x15, 0x82 }, // ISZERO DUP3
    .{ 0x16, 0x91 }, // AND SWAP2
    .{ 0x86, 0x61 }, // DUP7 PUSH2
    .{ 0x50, 0x82 }, // POP DUP3
    .{ 0x1C, 0x60 }, // SHR PUSH1
    .{ 0x84, 0x52 }, // DUP5 MSTORE
    .{ 0x81, 0x85 }, // DUP2 DUP6
    .{ 0x83, 0x52 }, // DUP4 MSTORE
    .{ 0x03, 0x83 }, // SUB DUP4
    .{ 0x16, 0x14 }, // AND EQ
    .{ 0x90, 0x80 }, // SWAP1 DUP1
    .{ 0x03, 0x80 }, // SUB DUP1
    .{ 0x85, 0x60 }, // DUP6 PUSH1
    .{ 0x95, 0x50 }, // SWAP6 POP
    .{ 0x19, 0x82 }, // NOT DUP3
    .{ 0x01, 0x83 }, // ADD DUP4
    .{ 0x90, 0x93 }, // SWAP1 SWAP4
    .{ 0x81, 0x84 }, // DUP2 DUP5
    .{ 0x35, 0x73 }, // CDLOAD PUSH20
    .{ 0x84, 0x82 }, // DUP5 DUP3
    .{ 0x83, 0x85 }, // DUP4 DUP6
    .{ 0x11, 0x17 }, // GT OR
    .{ 0x51, 0x82 }, // MLOAD DUP3
    .{ 0x01, 0x84 }, // ADD DUP5
    .{ 0x14, 0x17 }, // EQ OR
    .{ 0x81, 0x03 }, // DUP2 SUB
    .{ 0x91, 0x16 }, // SWAP2 AND
    .{ 0x91, 0x52 }, // SWAP2 MSTORE
    .{ 0x94, 0x50 }, // SWAP5 POP
    .{ 0x87, 0x61 }, // DUP8 PUSH2
    .{ 0x84, 0x14 }, // DUP5 EQ
    .{ 0x16, 0x92 }, // AND SWAP3
    .{ 0x83, 0x11 }, // DUP4 GT
    .{ 0x82, 0x15 }, // DUP3 ISZERO
    .{ 0x16, 0x7F }, // AND PUSH32
    .{ 0x16, 0x84 }, // AND DUP5
    .{ 0x5B, 0x60 }, // JUMPDEST PUSH1
    .{ 0x86, 0x86 }, // DUP7 DUP7
    .{ 0x93, 0x90 }, // SWAP4 SWAP1
    .{ 0x83, 0x36 }, // DUP4 CDSIZE
    .{ 0x1B, 0x81 }, // SHL DUP2
    .{ 0x85, 0x16 }, // DUP6 AND
    .{ 0x84, 0x83 }, // DUP5 DUP4
    .{ 0x94, 0x93 }, // SWAP5 SWAP4
    .{ 0x35, 0x91 }, // CDLOAD SWAP2
    .{ 0x50, 0x5F }, // POP PUSH0
    .{ 0x52, 0x91 }, // MSTORE SWAP2
    .{ 0x92, 0x01 }, // SWAP3 ADD
    .{ 0x51, 0x16 }, // MLOAD AND
    .{ 0x80, 0x85 }, // DUP1 DUP6
    .{ 0x02, 0x90 }, // MUL SWAP1
    .{ 0x91, 0x81 }, // SWAP2 DUP2
    .{ 0x19, 0x83 }, // NOT DUP4
    .{ 0x92, 0x83 }, // SWAP3 DUP4
    .{ 0x80, 0x5F }, // DUP1 PUSH0
    .{ 0x87, 0x01 }, // DUP8 ADD
    .{ 0x90, 0x51 }, // SWAP1 MLOAD
    .{ 0x90, 0x94 }, // SWAP1 SWAP5
    .{ 0x52, 0x34 }, // MSTORE CALLVALUE
    .{ 0x50, 0x03 }, // POP SUB
    .{ 0x82, 0x51 }, // DUP3 MLOAD
    .{ 0x01, 0x12 }, // ADD SLT
    .{ 0x92, 0x60 }, // SWAP3 PUSH1
    .{ 0x14, 0x90 }, // EQ SWAP1
    .{ 0x17, 0x15 }, // OR ISZERO
    .{ 0x57, 0x90 }, // JUMPI SWAP1
};

fn makeTable(comptime modern: bool) [65536]Handler {
    @setEvalBranchQuota(10_000_000);
    var singles: [256]Handler = undefined;
    for (0..256) |i| {
        const op: u8 = @intCast(i);
        singles[i] = if (model(op) == null or (!modern and gated(op))) &exit else if (!modern) plain(op) else single(op);
    }
    var t: [65536]Handler = undefined;
    for (0..65536) |k| t[k] = singles[k & 0xFF];
    for (fused_pairs) |p| {
        if (!modern and (gated(p[0]) or gated(p[1]))) continue;
        t[@as(usize, p[0]) | @as(usize, p[1]) << 8] = fused(p[0], p[1]);
    }
    return t;
}

const modern_table = makeTable(true);
const legacy_table = makeTable(false);

/// Calculate number of words from bytes
pub fn numWords(bytes: usize) usize {
    return (bytes + 31) / 32;
}
