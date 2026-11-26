const std = @import("std");

pub const Kind = enum {
    plain,
    branch_b,
    branch_bl,
    bti,
    b_cond,
    bc_cond,
    cbz,
    tbz,
    ldr_literal,
    adr,
    adrp,
};

pub fn classify(instruction: u32) Kind {
    if ((instruction & 0xFC000000) == 0x94000000) return .branch_bl;
    if ((instruction & 0x7C000000) == 0x14000000) return .branch_b;
    if ((instruction & 0xFFFFFF3F) == 0xD503241F) return .bti;
    if ((instruction & 0xFF000010) == 0x54000010) return .bc_cond;
    if ((instruction & 0xFF000010) == 0x54000000) return .b_cond;
    if ((instruction & 0x7E000000) == 0x34000000) return .cbz;
    if ((instruction & 0x7E000000) == 0x36000000) return .tbz;
    if ((instruction & 0x3B000000) == 0x18000000) return .ldr_literal;
    if ((instruction & 0x9F000000) == 0x10000000) return .adr;
    if ((instruction & 0x9F000000) == 0x90000000) return .adrp;
    return .plain;
}

pub fn isCopyable(kind: Kind) bool {
    return kind == .plain or kind == .bti;
}

pub fn branchDestination(instruction: u32, address: usize) usize {
    return @intCast(@as(i64, @intCast(address)) + branchImmediate(instruction));
}

pub fn branchImmediate(instruction: u32) i64 {
    var immediate: i64 = @intCast(instruction & 0x03FFFFFF);
    if ((immediate & 0x02000000) != 0) immediate -= 0x04000000;
    return immediate * 4;
}

pub fn encodeBranch(from: usize, to: usize) ?u32 {
    const delta = @as(i64, @intCast(to)) - @as(i64, @intCast(from));
    const limit = @as(i64, 1) << 27;
    if (delta < -limit * 4 or delta >= limit * 4 or @mod(delta, 4) != 0) return null;
    const words: i32 = @intCast(@divExact(delta, 4));
    return 0x14000000 | (@as(u32, @bitCast(words)) & 0x03FFFFFF);
}

pub fn encodeAdrp(from: usize, to_page: usize) ?u32 {
    const from_page = from & ~@as(usize, 0xFFF);
    const delta = @as(i64, @intCast(to_page)) - @as(i64, @intCast(from_page));
    if (@mod(delta, 4096) != 0) return null;
    const pages = @divExact(delta, 4096);
    if (pages < -(1 << 20) or pages >= (1 << 20)) return null;
    const immediate: u32 = @bitCast(@as(i32, @intCast(pages)));
    const immlo = immediate & 0x3;
    const immhi = (immediate >> 2) & 0x7FFFF;
    return 0x90000000 | (immlo << 29) | (immhi << 5) | 0;
}

test "classify arm64 instructions" {
    try std.testing.expectEqual(Kind.branch_b, classify(0x14000000));
    try std.testing.expectEqual(Kind.branch_b, classify(0x17FFE81C));
    try std.testing.expectEqual(Kind.branch_bl, classify(0x94000000));
    try std.testing.expectEqual(Kind.branch_bl, classify(0x97FFE81C));
    try std.testing.expectEqual(Kind.bti, classify(0xD503241F));
    try std.testing.expectEqual(Kind.bti, classify(0xD503245F));
    try std.testing.expectEqual(Kind.bti, classify(0xD503249F));
    try std.testing.expectEqual(Kind.bti, classify(0xD50324DF));
    try std.testing.expectEqual(Kind.b_cond, classify(0x54000000));
    try std.testing.expectEqual(Kind.bc_cond, classify(0x54000010));
    try std.testing.expectEqual(Kind.cbz, classify(0x34000000));
    try std.testing.expectEqual(Kind.cbz, classify(0x35000000));
    try std.testing.expectEqual(Kind.tbz, classify(0x36000000));
    try std.testing.expectEqual(Kind.tbz, classify(0x37000000));
    try std.testing.expectEqual(Kind.ldr_literal, classify(0x58000000));
    try std.testing.expectEqual(Kind.ldr_literal, classify(0x18000000));
    try std.testing.expectEqual(Kind.ldr_literal, classify(0x98000000));
    try std.testing.expectEqual(Kind.adr, classify(0x10000000));
    try std.testing.expectEqual(Kind.adrp, classify(0x90000000));
    try std.testing.expectEqual(Kind.plain, classify(0xA9BF7BFD));
    try std.testing.expectEqual(Kind.plain, classify(0xD10103FF));
}

test "encode branch" {
    const encoded = encodeBranch(0x10000, 0x10008) orelse return error.EncodeFailed;
    try std.testing.expectEqual(@as(u32, 0x14000002), encoded);
    try std.testing.expectEqual(@as(?u32, null), encodeBranch(0, 1));
    try std.testing.expectEqual(@as(?u32, null), encodeBranch(0, 1 << 30));
}

test "branch destination" {
    try std.testing.expectEqual(@as(usize, 0x10008), branchDestination(0x14000001, 0x10004));
    try std.testing.expectEqual(@as(usize, 0x10000), branchDestination(0x17FFFFFF, 0x10004));
}

test "encode adrp" {
    const encoded = encodeAdrp(0x10000, 0x12000) orelse return error.EncodeFailed;
    try std.testing.expectEqual(@as(u32, 0xD0000000), encoded);
}
