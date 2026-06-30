/// Guest (zkVM) backend for the u256 arithmetic accelerator interface (u256_math.zig).
///
/// Calls the zkvm-standards U256 circuit accelerators (zkvm_u256.h). `zkvm_u256`
/// is the standard's `zkvm_bytes_32`; we pass zesu's native u256 reinterpreted in
/// place — no byte-order conversion. The per-zkVM substitution shim adapts the
/// word order to its accelerator: for ZisK (little-endian limbs) the cast is
/// zero-cost; a big-endian accelerator would convert in its own shim.
///
/// Also exports the software fallback (zesu_u256_*, forwarding to the native
/// backend) that zkVM targets without a native U256 accelerator forward to. Only
/// compiled into guest builds (this file is the freestanding u256_impl), so these
/// exports never appear natively.
const soft = @import("native_u256.zig");

const Zkvm_u256 = [32]u8;
extern fn zkvm_u256_mod(a: *const Zkvm_u256, b: *const Zkvm_u256, remainder: *Zkvm_u256) i32;
extern fn zkvm_u256_addmod(a: *const Zkvm_u256, b: *const Zkvm_u256, n: *const Zkvm_u256, result: *Zkvm_u256) i32;
extern fn zkvm_u256_mulmod(a: *const Zkvm_u256, b: *const Zkvm_u256, n: *const Zkvm_u256, result: *Zkvm_u256) i32;
extern fn zkvm_u256_div(a: *const Zkvm_u256, b: *const Zkvm_u256, quotient: *Zkvm_u256) i32;

// Zero-modulus / zero-divisor guards match EVM semantics (result 0) and keep that
// case away from the accelerator.

pub fn mod256(a: u256, n: u256) u256 {
    if (n == 0) return 0;
    var out: u256 = undefined;
    _ = zkvm_u256_mod(@ptrCast(&a), @ptrCast(&n), @ptrCast(&out));
    return out;
}

pub fn addmod(a: u256, b: u256, n: u256) u256 {
    if (n == 0) return 0;
    var out: u256 = undefined;
    _ = zkvm_u256_addmod(@ptrCast(&a), @ptrCast(&b), @ptrCast(&n), @ptrCast(&out));
    return out;
}

pub fn mulmod(a: u256, b: u256, n: u256) u256 {
    if (n == 0) return 0;
    var out: u256 = undefined;
    _ = zkvm_u256_mulmod(@ptrCast(&a), @ptrCast(&b), @ptrCast(&n), @ptrCast(&out));
    return out;
}

pub fn div256(a: u256, b: u256) u256 {
    if (b == 0) return 0;
    var out: u256 = undefined;
    _ = zkvm_u256_div(@ptrCast(&a), @ptrCast(&b), @ptrCast(&out));
    return out;
}

// ── Software fallback (zesu_u256_*) ───────────────────────────────────────────
// C symbols zkVM targets without a native U256 accelerator forward their
// zkvm_u256_* shim to. `zkvm_u256` carries the caller's native word, so on a
// little-endian target @bitCast round-trips with no byte-order swap.
fn val(p: *const Zkvm_u256) u256 {
    return @bitCast(p.*);
}

export fn zesu_u256_mod(a: *const Zkvm_u256, b: *const Zkvm_u256, remainder: *Zkvm_u256) i32 {
    remainder.* = @bitCast(soft.mod256(val(a), val(b)));
    return 0;
}

export fn zesu_u256_addmod(a: *const Zkvm_u256, b: *const Zkvm_u256, n: *const Zkvm_u256, result: *Zkvm_u256) i32 {
    result.* = @bitCast(soft.addmod(val(a), val(b), val(n)));
    return 0;
}

export fn zesu_u256_mulmod(a: *const Zkvm_u256, b: *const Zkvm_u256, n: *const Zkvm_u256, result: *Zkvm_u256) i32 {
    result.* = @bitCast(soft.mulmod(val(a), val(b), val(n)));
    return 0;
}

export fn zesu_u256_div(a: *const Zkvm_u256, b: *const Zkvm_u256, quotient: *Zkvm_u256) i32 {
    quotient.* = @bitCast(soft.div256(val(a), val(b)));
    return 0;
}
