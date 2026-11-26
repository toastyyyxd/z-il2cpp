const std = @import("std");

pub const Decoded = struct {
    length: usize = 0,
    rip_disp_offset: ?usize = null,
    relative: bool = false,
    ok: bool = false,
};

const prefix_bytes = [_]u8{ 0xF0, 0xF2, 0xF3, 0x2E, 0x36, 0x3E, 0x26, 0x64, 0x65, 0x66, 0x67 };

fn hasModRm(opcode: u8) bool {
    return switch (opcode) {
        0x00...0x03, 0x08...0x0B, 0x10...0x13, 0x18...0x1B, 0x20...0x23, 0x28...0x2B, 0x30...0x33, 0x38...0x3B, 0x62, 0x63, 0x69, 0x6B, 0x80...0x8F, 0xC0, 0xC1, 0xC6, 0xC7, 0xD0...0xD3, 0xD8...0xDF, 0xF6, 0xF7, 0xFE, 0xFF => true,
        else => false,
    };
}

fn immediateSize(opcode: u8, reg: u8, operand16: bool) ?usize {
    return switch (opcode) {
        0x69, 0x81, 0xC7 => if (operand16) 2 else 4,
        0x6B, 0x80, 0x82, 0x83, 0xC0, 0xC1, 0xC6 => 1,
        0xF6 => if (reg == 0 or reg == 1) 1 else null,
        0xF7 => if (reg == 0 or reg == 1) (if (operand16) 2 else 4) else null,
        else => null,
    };
}

pub fn decode(code: *const [16]u8) Decoded {
    var index: usize = 0;
    var operand16 = false;
    var address32 = false;
    var rex_w = false;

    while (index < 15) {
        const byte = code[index];
        if (std.mem.indexOfScalar(u8, &prefix_bytes, byte) != null) {
            if (byte == 0x66) operand16 = true;
            if (byte == 0x67) address32 = true;
            index += 1;
            continue;
        }
        if (byte >= 0x40 and byte <= 0x4F) {
            rex_w = (byte & 0x08) != 0;
            index += 1;
            continue;
        }
        break;
    }
    if (index >= 16) return .{};

    const opcode = code[index];
    index += 1;

    var result = Decoded{ .relative = false };
    var modrm_required = false;
    var imm_size: usize = 0;

    if (opcode == 0x0F) {
        if (index >= 16) return .{};
        const opcode2 = code[index];
        index += 1;
        switch (opcode2) {
            0x1E, 0x1F, 0x28, 0x29, 0x10, 0x11, 0x40...0x4F, 0x6E, 0x6F, 0x7E, 0x7F, 0x57, 0x58, 0x59, 0x5C, 0x5D, 0x5E, 0x5F, 0xB6, 0xB7, 0xBE, 0xBF, 0xAF, 0xEF, 0x2E, 0x2F => {
                modrm_required = true;
            },
            0x05, 0x0B => {},
            0x80...0x8F => {
                result.relative = true;
                imm_size = if (operand16) 2 else 4;
            },
            else => return .{},
        }
    } else {
        switch (opcode) {
            0x50...0x5F, 0x90, 0xC3, 0xC9, 0xCC, 0xF4, 0xFC, 0xFD, 0x0B, 0x31 => {},
            0x68 => imm_size = if (operand16) 2 else 4,
            0x6A => imm_size = 1,
            0xE8, 0xE9 => {
                result.relative = true;
                imm_size = if (operand16) 2 else 4;
            },
            0xEB, 0x70...0x7F, 0xE0...0xE3 => {
                result.relative = true;
                imm_size = 1;
            },
            0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C => imm_size = 1,
            0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D => imm_size = if (operand16) 2 else 4,
            0xB0...0xB7 => imm_size = 1,
            0xB8...0xBF => imm_size = if (rex_w) 8 else if (operand16) 2 else 4,
            0xA8 => imm_size = 1,
            0xA9 => imm_size = if (operand16) 2 else 4,
            0xC2, 0xCA => imm_size = 2,
            0xCD, 0xD4, 0xD5 => imm_size = 1,
            else => {
                if (!hasModRm(opcode)) return .{};
                modrm_required = true;
            },
        }
    }

    if (modrm_required) {
        if (index >= 16) return .{};
        const modrm = code[index];
        index += 1;
        const mod = modrm >> 6;
        const reg = (modrm >> 3) & 7;
        const rm = modrm & 7;
        if (mod != 3) {
            if (rm == 4) {
                if (index >= 16) return .{};
                const sib = code[index];
                index += 1;
                if (mod == 0 and (sib & 7) == 5) {
                    index += 4;
                }
            }
            if (mod == 0 and rm == 5 and !address32) {
                result.rip_disp_offset = index;
                index += 4;
            } else if (mod == 1) {
                index += 1;
            } else if (mod == 2) {
                index += 4;
            }
        }
        if (immediateSize(opcode, reg, operand16)) |size| imm_size = size;
        if (opcode == 0x0F) {
            // handled by the two-byte table above; immediate sizes are not used there
            imm_size = 0;
        }
        if (opcode == 0x0F) imm_size = 0;
    }

    index += imm_size;
    if (index > 16 or index == 0) return .{};
    result.length = index;
    result.ok = true;
    return result;
}

test "decode endbr64" {
    const bytes = [16]u8{ 0xF3, 0x0F, 0x1E, 0xFA, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const decoded = decode(&bytes);
    try std.testing.expect(decoded.ok);
    try std.testing.expectEqual(@as(usize, 4), decoded.length);
    try std.testing.expect(!decoded.relative);
}

test "decode push rbp and mov rbp rsp" {
    const push = [16]u8{ 0x55, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const mov = [16]u8{ 0x48, 0x89, 0xE5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(usize, 1), decode(&push).length);
    try std.testing.expectEqual(@as(usize, 3), decode(&mov).length);
}

test "decode sub rsp immediate" {
    const short = [16]u8{ 0x48, 0x83, 0xEC, 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const long = [16]u8{ 0x48, 0x81, 0xEC, 0x20, 0x01, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(usize, 4), decode(&short).length);
    try std.testing.expectEqual(@as(usize, 7), decode(&long).length);
}

test "decode rip relative load" {
    const bytes = [16]u8{ 0x48, 0x8B, 0x05, 0x10, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const decoded = decode(&bytes);
    try std.testing.expect(decoded.ok);
    try std.testing.expectEqual(@as(usize, 7), decoded.length);
    try std.testing.expectEqual(@as(?usize, 3), decoded.rip_disp_offset);
}

test "decode relative branch is marked" {
    const bytes = [16]u8{ 0xE8, 0x10, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const decoded = decode(&bytes);
    try std.testing.expect(decoded.relative);
    try std.testing.expectEqual(@as(usize, 5), decoded.length);
}
