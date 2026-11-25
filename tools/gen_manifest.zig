const std = @import("std");
const Io = std.Io;

pub const sha256_hex_length = 64;

pub fn hashHex(data: []const u8) [sha256_hex_length]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn appendEntry(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    name: []const u8,
    data: []const u8,
) !void {
    const hex = hashHex(data);
    const line = try std.fmt.allocPrint(
        gpa,
        "    {{\"name\": \"{s}\", \"size\": {d}, \"sha256\": \"{s}\"}}",
        .{ name, data.len, hex },
    );
    defer gpa.free(line);
    try out.appendSlice(gpa, line);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 4 or (args.len - 2) % 2 != 0) {
        std.debug.print("usage: gen-manifest <out.json> [<name> <path>]...\n", .{});
        return error.InvalidArguments;
    }

    var json: std.ArrayList(u8) = .empty;
    try json.appendSlice(arena, "{\n  \"files\": [\n");

    var index: usize = 2;
    var first = true;
    while (index + 1 < args.len) : (index += 2) {
        const name = args[index];
        const path = args[index + 1];
        const data = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024 * 1024));
        if (!first) try json.appendSlice(arena, ",\n");
        first = false;
        try appendEntry(&json, arena, name, data);
    }

    try json.appendSlice(arena, "\n  ]\n}\n");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = json.items });
    std.debug.print("gen-manifest: wrote {s} ({d} entries)\n", .{ args[1], (args.len - 2) / 2 });
}

const testing = std.testing;

test "sha256 of empty input" {
    const hex = hashHex("");
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &hex,
    );
}

test "sha256 of 'abc'" {
    const hex = hashHex("abc");
    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &hex,
    );
}

test "manifest entry serializes name, size and hash" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try appendEntry(&out, gpa, "hot-test.bin", "abc");
    try testing.expectEqualStrings(
        "    {\"name\": \"hot-test.bin\", \"size\": 3, \"sha256\": " ++
            "\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"}",
        out.items,
    );
}
