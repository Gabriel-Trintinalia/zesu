const std = @import("std");
const primitives = @import("primitives");
const InstructionContext = @import("../instruction_context.zig").InstructionContext;
const InstructionFn = @import("../instruction_context.zig").InstructionFn;

/// POP opcode (0x50): Remove top item from stack
/// Stack: [a] -> []   Gas: 2 (G_BASE, charged by dispatch)
pub fn opPop(ctx: *InstructionContext) void {
    const stack = &ctx.interpreter.stack;
    if (!stack.hasItems(1)) {
        ctx.interpreter.halt(.stack_underflow);
        return;
    }
    stack.shrinkUnsafe(1);
}

/// PUSH0 opcode (0x5F): Push 0 onto stack (Shanghai+)
/// Stack: [] -> [0]   Gas: 2 (G_BASE, charged by dispatch)
pub fn opPush0(ctx: *InstructionContext) void {
    const stack = &ctx.interpreter.stack;
    if (!stack.hasSpace(1)) {
        ctx.interpreter.halt(.stack_overflow);
        return;
    }
    stack.pushUnsafe(0);
}

/// Inline implementation for PUSH1..PUSH32, callable with comptime n from runDispatch.
/// Reads n immediate bytes, pushes as big-endian U256, advances PC by n.
pub inline fn opPushNImpl(ctx: *InstructionContext, comptime n: u8) void {
    const stack = &ctx.interpreter.stack;
    if (!stack.hasSpace(1)) {
        ctx.interpreter.halt(.stack_overflow);
        return;
    }
    const U = primitives.U256;
    const ext = &ctx.interpreter.bytecode;
    const bytes = ext.bytecode.bytecode();
    const pc = ext.pc;

    // Gated on n by measurement, not taste. The direct big-endian read wins big for wide
    // operands (PUSH9 -19.7%, PUSH17 -15.9%, PUSH26 -20.1% on the EEST 0010M tier) but
    // loses for narrow ones (PUSH1 +7.6%), and narrow pushes dominate real bytecode — an
    // ungated rewrite regressed both mainnet (+0.04%) and the tier (+0.38%). The narrow
    // loss is ~10 extra non-chip instructions per push inside the inlined dispatch arm;
    // it is not the readInt lowering, a u256 phi spill, or shift-vs-mask billing (all
    // three tested and ruled out). So keep the buffer form where it already wins.
    if (n <= 8) {
        var buf: [32]u8 = .{0} ** 32;
        if (pc + n <= bytes.len) {
            @memcpy(buf[32 - n ..], bytes[pc .. pc + n]);
        } else if (pc < bytes.len) {
            @memcpy(buf[32 - n ..][0 .. bytes.len - pc], bytes[pc..]);
        }
        stack.pushUnsafe((@as(U, std.mem.readInt(u64, buf[0..8], .big)) << 192) |
            (@as(U, std.mem.readInt(u64, buf[8..16], .big)) << 128) |
            (@as(U, std.mem.readInt(u64, buf[16..24], .big)) << 64) |
            @as(U, std.mem.readInt(u64, buf[24..32], .big)));
    } else if (pc + n <= bytes.len) {
        // Wide operand, wholly in bounds: one comptime-sized big-endian read straight off
        // the bytecode. With unaligned-scalar-mem (build.zig) that is a few loads and
        // byteswaps, with no zeroed 32-byte buffer and no unaligned @memcpy.
        const Imm = @Int(.unsigned, @as(u16, n) * 8);
        stack.pushUnsafe(@as(U, std.mem.readInt(Imm, bytes[pc..][0..n], .big)));
    } else {
        // Wide operand, code ends at or mid-operand: missing tail reads as zero, i.e. the
        // available bytes are the most significant of the n-byte field.
        var buf: [32]u8 = .{0} ** 32;
        if (pc < bytes.len) @memcpy(buf[32 - n ..][0 .. bytes.len - pc], bytes[pc..]);
        stack.pushUnsafe((@as(U, std.mem.readInt(u64, buf[0..8], .big)) << 192) |
            (@as(U, std.mem.readInt(u64, buf[8..16], .big)) << 128) |
            (@as(U, std.mem.readInt(u64, buf[16..24], .big)) << 64) |
            @as(U, std.mem.readInt(u64, buf[24..32], .big)));
    }
    ctx.interpreter.bytecode.relativeJump(n);
}

/// Comptime PUSH generator for PUSH1..PUSH32.
/// Reads n immediate bytes at current PC, pushes as big-endian U256, advances PC by n.
/// Static gas (G_VERYLOW) is charged by the dispatch loop.
pub fn makePushFn(comptime n: u8) InstructionFn {
    return struct {
        fn op(ctx: *InstructionContext) void {
            opPushNImpl(ctx, n);
        }
    }.op;
}

/// Inline implementation for DUP1..DUP16, callable with comptime n from runDispatch.
pub inline fn opDupNImpl(ctx: *InstructionContext, comptime n: u8) void {
    const stack = &ctx.interpreter.stack;
    if (!stack.hasItems(n)) {
        ctx.interpreter.halt(.stack_underflow);
        return;
    }
    if (!stack.hasSpace(1)) {
        ctx.interpreter.halt(.stack_overflow);
        return;
    }
    stack.dupUnsafe(n);
}

/// Comptime DUP generator for DUP1..DUP16.
/// Duplicates the nth stack item (1-indexed from top).
/// Static gas (G_VERYLOW) is charged by the dispatch loop.
pub fn makeDupFn(comptime n: u8) InstructionFn {
    return struct {
        fn op(ctx: *InstructionContext) void {
            opDupNImpl(ctx, n);
        }
    }.op;
}

/// Inline implementation for SWAP1..SWAP16, callable with comptime n from runDispatch.
pub inline fn opSwapNImpl(ctx: *InstructionContext, comptime n: u8) void {
    const stack = &ctx.interpreter.stack;
    if (!stack.hasItems(n + 1)) {
        ctx.interpreter.halt(.stack_underflow);
        return;
    }
    stack.swapUnsafe(n);
}

/// Comptime SWAP generator for SWAP1..SWAP16.
/// Swaps top of stack with the (n+1)th item.
/// Static gas (G_VERYLOW) is charged by the dispatch loop.
pub fn makeSwapFn(comptime n: u8) InstructionFn {
    return struct {
        fn op(ctx: *InstructionContext) void {
            opSwapNImpl(ctx, n);
        }
    }.op;
}

/// DUPN (0xE6): Duplicate item at depth n from top (EIP-8024, Amsterdam+).
/// Reads 1 immediate byte `imm`. Valid range: 0..=90 or 128..=255 (91..=127 → exceptional halt).
/// Depth n = decode_single(imm) = (imm + 145) % 256, with 17 <= n <= 235.
/// Gas: 3 (G_VERYLOW, charged by dispatch).
pub fn opDupN(ctx: *InstructionContext) void {
    const stack = &ctx.interpreter.stack;
    const imm = ctx.interpreter.bytecode.readImmediate();
    ctx.interpreter.bytecode.relativeJump(1);
    // EIP-8024: immediates 91..=127 (0x5B..=0x7F) are invalid per decode_single.
    if (imm > 90 and imm < 128) {
        ctx.interpreter.halt(.invalid_opcode);
        return;
    }
    const n: usize = (@as(usize, imm) + 145) % 256;
    // n == 0 or n <= 16: depth 0 is invalid, depths 1-16 overlap DUP1-DUP16 (also invalid for DUPN).
    if (n <= 16 or !stack.hasItems(n)) {
        ctx.interpreter.halt(.stack_underflow);
        return;
    }
    if (!stack.hasSpace(1)) {
        ctx.interpreter.halt(.stack_overflow);
        return;
    }
    stack.dupUnsafe(n);
}

/// SWAPN (0xE7): Swap top with item at 0-indexed depth n (EIP-8024, Amsterdam+).
/// Reads 1 immediate byte `imm`. Valid range: 0..=90 or 128..=255 (91..=127 → exceptional halt).
/// Depth n = decode_single(imm) = (imm + 145) % 256, with 17 <= n <= 235.
/// Gas: 3 (G_VERYLOW, charged by dispatch).
pub fn opSwapN(ctx: *InstructionContext) void {
    const stack = &ctx.interpreter.stack;
    const imm = ctx.interpreter.bytecode.readImmediate();
    ctx.interpreter.bytecode.relativeJump(1);
    // EIP-8024: immediates 91..=127 (0x5B..=0x7F) are invalid per decode_single.
    if (imm > 90 and imm < 128) {
        ctx.interpreter.halt(.invalid_opcode);
        return;
    }
    const n: usize = (@as(usize, imm) + 145) % 256;
    if (!stack.hasItems(n + 1)) {
        ctx.interpreter.halt(.stack_underflow);
        return;
    }
    stack.swapUnsafe(n);
}

/// EXCHANGE (0xE8): Swap two non-top stack items (EIP-8024, Amsterdam+).
/// Immediate byte `x` decoded via EIP-8024 decode_pair:
///   k = x ^ 143; q = k >> 4; r = k & 0xF
///   if q < r: n = q+1, m = r+1
///   else:     n = r+1, m = 29-q
/// Valid range: 0..=81 or 128..=255 (82..=127 → exceptional failure).
/// Swaps stack[top - n] and stack[top - m], needs m+1 items (n < m always).
/// Gas: 3 (G_VERYLOW, charged by dispatch).
pub fn opExchange(ctx: *InstructionContext) void {
    const stack = &ctx.interpreter.stack;
    const imm = ctx.interpreter.bytecode.readImmediate();
    ctx.interpreter.bytecode.relativeJump(1);
    // Immediates 82..=127 (0x52..=0x7F) are invalid per EIP-8024.
    if (imm >= 82 and imm <= 127) {
        ctx.interpreter.halt(.invalid_opcode);
        return;
    }
    // decode_pair: k = imm XOR 143, q = k >> 4, r = k & 0xF
    const k: usize = @as(usize, imm) ^ 143;
    const q: usize = k >> 4;
    const r: usize = k & 0xF;
    const n: usize = if (q < r) q + 1 else r + 1; // smaller depth (1..14)
    const m: usize = if (q < r) r + 1 else 29 - q; // larger depth (n < m)
    // Need m+1 items on stack.
    if (!stack.hasItems(m + 1)) {
        ctx.interpreter.halt(.stack_underflow);
        return;
    }
    const top_idx = stack.length - 1;
    const tmp = stack.data[top_idx - n];
    stack.data[top_idx - n] = stack.data[top_idx - m];
    stack.data[top_idx - m] = tmp;
}

test {
    _ = @import("stack_tests.zig");
}
