const std = @import("std");
const Io = std.Io;

pub const Error = error{
    NotPortableExecutable,
    Truncated,
    UnsupportedOptionalHeader,
    NoTlsDirectoryEntry,
};

pub const TlsInfo = struct {
    rva: u32,
    size: u32,
    already_stripped: bool,
};

const pe_signature: u32 = 0x0000_4550;
const optional_magic_pe32: u16 = 0x010b;
const optional_magic_pe32_plus: u16 = 0x020b;
const tls_directory_index: usize = 9;

fn readU16(bytes: []const u8, offset: usize) Error!u16 {
    if (offset + 2 > bytes.len) return Error.Truncated;
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) Error!u32 {
    if (offset + 4 > bytes.len) return Error.Truncated;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) Error!void {
    if (offset + 4 > bytes.len) return Error.Truncated;
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

pub fn stripTls(bytes: []u8) Error!TlsInfo {
    if (bytes.len < 0x40) return Error.Truncated;
    if (bytes[0] != 'M' or bytes[1] != 'Z') return Error.NotPortableExecutable;

    const pe_offset = try readU32(bytes, 0x3c);
    const coff_offset = @as(usize, pe_offset) + 4;
    if (try readU32(bytes, pe_offset) != pe_signature) return Error.NotPortableExecutable;

    const optional_size = try readU16(bytes, coff_offset + 16);
    const optional_offset = coff_offset + 20;
    if (optional_offset + optional_size > bytes.len) return Error.Truncated;

    const magic = try readU16(bytes, optional_offset);
    const layout: struct { data_directory: usize, number_of_rva: usize } = switch (magic) {
        optional_magic_pe32 => .{ .data_directory = optional_offset + 96, .number_of_rva = optional_offset + 92 },
        optional_magic_pe32_plus => .{ .data_directory = optional_offset + 112, .number_of_rva = optional_offset + 108 },
        else => return Error.UnsupportedOptionalHeader,
    };

    if (try readU32(bytes, layout.number_of_rva) <= tls_directory_index) {
        return Error.NoTlsDirectoryEntry;
    }

    const tls_entry = layout.data_directory + tls_directory_index * 8;
    const rva = try readU32(bytes, tls_entry);
    const size = try readU32(bytes, tls_entry + 4);
    if (rva == 0 and size == 0) {
        return .{ .rva = 0, .size = 0, .already_stripped = true };
    }

    try writeU32(bytes, tls_entry, 0);
    try writeU32(bytes, tls_entry + 4, 0);
    return .{ .rva = rva, .size = size, .already_stripped = false };
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len != 3) {
        std.debug.print("usage: strip-pe-tls <input> <output>\n", .{});
        return error.InvalidArguments;
    }

    const input_path = args[1];
    const output_path = args[2];
    const data = try Io.Dir.cwd().readFileAlloc(io, input_path, arena, .limited(256 * 1024 * 1024));
    const info = try stripTls(data);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = data });

    if (info.already_stripped) {
        std.debug.print("strip-pe-tls: {s}: no TLS directory; copied to {s}\n", .{ input_path, output_path });
    } else {
        std.debug.print(
            "strip-pe-tls: {s}: removed TLS directory (rva=0x{x} size={d}) -> {s}\n",
            .{ input_path, info.rva, info.size, output_path },
        );
    }
}

const testing = std.testing;

const synthetic_pe32_plus_size = 0x300;

fn writeSyntheticPe32Plus(bytes: []u8, tls_rva: u32, tls_size: u32) void {
    @memset(bytes, 0);
    bytes[0] = 'M';
    bytes[1] = 'Z';
    std.mem.writeInt(u32, bytes[0x3c..][0..4], 0x40, .little);
    std.mem.writeInt(u32, bytes[0x40..][0..4], pe_signature, .little);

    const coff_offset = 0x44;
    std.mem.writeInt(u16, bytes[coff_offset + 16 ..][0..2], 240, .little);
    const optional_offset = coff_offset + 20;
    std.mem.writeInt(u16, bytes[optional_offset..][0..2], optional_magic_pe32_plus, .little);
    std.mem.writeInt(u32, bytes[optional_offset + 108 ..][0..4], 16, .little);

    const tls_entry = optional_offset + 112 + tls_directory_index * 8;
    std.mem.writeInt(u32, bytes[tls_entry..][0..4], tls_rva, .little);
    std.mem.writeInt(u32, bytes[tls_entry + 4 ..][0..4], tls_size, .little);
}

test "strips a PE32+ TLS directory" {
    var image: [synthetic_pe32_plus_size]u8 = undefined;
    writeSyntheticPe32Plus(&image, 0x2000, 40);

    const info = try stripTls(&image);
    try testing.expectEqual(@as(u32, 0x2000), info.rva);
    try testing.expectEqual(@as(u32, 40), info.size);
    try testing.expect(!info.already_stripped);

    const tls_entry = 0x44 + 20 + 112 + tls_directory_index * 8;
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, image[tls_entry..][0..4], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, image[tls_entry + 4 ..][0..4], .little));

    const again = try stripTls(&image);
    try testing.expect(again.already_stripped);
}

test "rejects non-PE input" {
    var garbage: [0x200]u8 = @splat(0);
    try testing.expectError(Error.NotPortableExecutable, stripTls(&garbage));
}

test "rejects truncated input" {
    var truncated: [0x20]u8 = @splat(0);
    try testing.expectError(Error.Truncated, stripTls(&truncated));
}

test "rejects unsupported optional header" {
    var image: [synthetic_pe32_plus_size]u8 = undefined;
    writeSyntheticPe32Plus(&image, 0x2000, 40);
    std.mem.writeInt(u16, image[0x44 + 20 ..][0..2], 0x9999, .little);
    try testing.expectError(Error.UnsupportedOptionalHeader, stripTls(&image));
}
