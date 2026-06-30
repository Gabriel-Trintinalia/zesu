/// Native backend for the u256 arithmetic accelerator interface (u256_math.zig).
///
/// Pure software wide-integer / hardware arithmetic. Also the source of the guest
/// software fallback (extern_u256.zig's zesu_u256_* exports forward here). All
/// return 0 when the modulus / divisor is 0, matching EVM semantics.
pub fn mod256(a: u256, n: u256) u256 {
    if (n == 0) return 0;
    return a % n;
}

pub fn div256(a: u256, b: u256) u256 {
    if (b == 0) return 0;
    return a / b;
}

pub fn addmod(a: u256, b: u256, n: u256) u256 {
    if (n == 0) return 0;
    // 257-bit intermediate so a + b cannot overflow before the reduction.
    return @intCast((@as(u257, a) + @as(u257, b)) % @as(u257, n));
}

pub fn mulmod(a: u256, b: u256, n: u256) u256 {
    if (n == 0) return 0;
    // 512-bit intermediate so a * b cannot overflow before the reduction.
    return @intCast((@as(u512, a) * @as(u512, b)) % @as(u512, n));
}
