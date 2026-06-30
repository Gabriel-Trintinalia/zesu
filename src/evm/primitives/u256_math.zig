/// 256-bit arithmetic accelerator interface for the EVM arithmetic opcodes
/// (MOD/ADDMOD/MULMOD/DIV/SDIV/SMOD).
///
/// Thin adapter over the build-injected `u256_impl` backend:
///   native: native_u256.zig (software wide-integer / hardware arithmetic)
///   zkvm:   extern_u256.zig  (zkvm-standards zkvm_u256_* circuit accelerators)
///
/// All return 0 when the modulus / divisor is 0, matching EVM semantics.
const impl = @import("u256_impl");

/// MOD (opcode 0x06): a mod n.
pub inline fn mod256(a: u256, n: u256) u256 {
    return impl.mod256(a, n);
}

/// ADDMOD (opcode 0x08): (a + b) mod n.
pub inline fn addmod(a: u256, b: u256, n: u256) u256 {
    return impl.addmod(a, b, n);
}

/// MULMOD (opcode 0x09): (a * b) mod n.
pub inline fn mulmod(a: u256, b: u256, n: u256) u256 {
    return impl.mulmod(a, b, n);
}

/// Unsigned 256-bit division a / b (DIV opcode 0x04; also the magnitude
/// division inside signed SDIV 0x05). Returns 0 when b == 0.
pub inline fn div256(a: u256, b: u256) u256 {
    return impl.div256(a, b);
}
