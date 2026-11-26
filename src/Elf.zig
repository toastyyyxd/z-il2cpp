const std = @import("std");

const ELF_MAGIC = [4]u8{ 0x7f, 0x45, 0x4c, 0x46 };
const PT_LOAD = 1;
const PT_DYNAMIC = 2;
const DT_NULL = 0;
const DT_HASH = 4;
const DT_STRTAB = 5;
const DT_SYMTAB = 6;
const DT_STRSZ = 10;
const DT_SYMENT = 11;
const DT_GNU_HASH = 0x6ffffef5;

const ElfHeader = extern struct {
    ident: [16]u8,
    type: u16,
    machine: u16,
    version: u32,
    entry: u64,
    phoff: u64,
    shoff: u64,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,
};

const ProgramHeader = extern struct {
    type: u32,
    flags: u32,
    offset: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    alignment: u64,
};

const Dynamic = extern struct {
    tag: i64,
    value: u64,
};

const Symbol = extern struct {
    name: u32,
    info: u8,
    other: u8,
    shndx: u16,
    value: u64,
    size: u64,
};

pub fn findLibraryBase(maps: []const u8, library_name: []const u8) ?usize {
    var line_start: usize = 0;
    var index: usize = 0;
    while (index <= maps.len) : (index += 1) {
        const at_end = index == maps.len or maps[index] == '\n';
        if (!at_end) continue;
        const line = maps[line_start..index];
        line_start = index + 1;
        if (std.mem.indexOf(u8, line, library_name) == null) continue;
        var cursor: usize = 0;
        const start = parseHex(line, &cursor) orelse continue;
        return @intCast(start);
    }
    return null;
}

pub fn findSymbol(base: usize, target_name: []const u8) ?*anyopaque {
    const header: *const ElfHeader = @ptrFromInt(base);
    if (!std.mem.eql(u8, header.ident[0..4], &ELF_MAGIC)) return null;
    if (header.ident[4] != 2) return null;

    const program_headers: [*]const ProgramHeader = @ptrFromInt(base + header.phoff);
    var dynamic_address: usize = 0;
    var header_index: usize = 0;
    while (header_index < header.phnum) : (header_index += 1) {
        if (program_headers[header_index].type == PT_DYNAMIC) {
            dynamic_address = base + @as(usize, @intCast(program_headers[header_index].vaddr));
            break;
        }
    }
    if (dynamic_address == 0) return null;

    var string_table: usize = 0;
    var symbol_table: usize = 0;
    var hash_table: usize = 0;
    var gnu_hash_table: usize = 0;
    var string_size: usize = 0;
    var symbol_size: usize = 24;

    const dynamics: [*]const Dynamic = @ptrFromInt(dynamic_address);
    var dynamic_index: usize = 0;
    while (dynamics[dynamic_index].tag != DT_NULL) : (dynamic_index += 1) {
        const value = @as(usize, @intCast(dynamics[dynamic_index].value));
        switch (dynamics[dynamic_index].tag) {
            DT_STRTAB => string_table = base + value,
            DT_SYMTAB => symbol_table = base + value,
            DT_HASH => hash_table = base + value,
            DT_GNU_HASH => gnu_hash_table = base + value,
            DT_STRSZ => string_size = value,
            DT_SYMENT => symbol_size = value,
            else => {},
        }
    }
    if (string_table == 0 or symbol_table == 0) return null;

    var symbol_count: usize = 0;
    if (gnu_hash_table != 0) {
        const hash_words: [*]const u32 = @ptrFromInt(gnu_hash_table);
        const bucket_count = hash_words[0];
        const symbol_offset = hash_words[1];
        const bloom_size = hash_words[2];
        const buckets_address = gnu_hash_table + 16 + bloom_size * @sizeOf(usize);
        const buckets: [*]const u32 = @ptrFromInt(buckets_address);
        const chains: [*]const u32 = @ptrFromInt(buckets_address + bucket_count * @sizeOf(u32));
        var bucket_index: usize = 0;
        while (bucket_index < bucket_count) : (bucket_index += 1) {
            var symbol_index = buckets[bucket_index];
            if (symbol_index == 0) continue;
            while (true) {
                const chain = chains[symbol_index - symbol_offset];
                if (symbol_index > symbol_count) symbol_count = symbol_index + 1;
                symbol_index += 1;
                if ((chain & 1) != 0) break;
            }
        }
    } else if (hash_table != 0) {
        const hash_words: [*]const u32 = @ptrFromInt(hash_table);
        symbol_count = hash_words[1];
    }
    if (symbol_count == 0) return null;

    const symbols: [*]const Symbol = @ptrFromInt(symbol_table);
    const strings: [*]const u8 = @ptrFromInt(string_table);
    var index: usize = 0;
    while (index < symbol_count) : (index += 1) {
        const symbol = &symbols[index];
        if (symbol.name == 0 or symbol.name >= string_size) continue;
        const name_pointer = strings + symbol.name;
        var name_length: usize = 0;
        while (name_pointer[name_length] != 0) name_length += 1;
        if (!std.mem.eql(u8, name_pointer[0..name_length], target_name)) continue;
        if (symbol.shndx == 0) return null;
        return @ptrFromInt(base + @as(usize, @intCast(symbol.value)));
    }
    return null;
}

fn parseHex(text: []const u8, index: *usize) ?u64 {
    var value: u64 = 0;
    var digits: usize = 0;
    while (index.* < text.len) {
        const byte = text[index.*];
        const digit: u8 = switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            'A'...'F' => byte - 'A' + 10,
            else => break,
        };
        value = value * 16 + digit;
        index.* += 1;
        digits += 1;
    }
    if (digits == 0) return null;
    return value;
}

test "find library base in maps text" {
    const maps =
        "1000-2000 r-xp 00000000 00:00 0 /system/lib64/libfoo.so\n" ++
        "3000-4000 r--p 00000000 00:00 0 /data/app/libbar.so\n" ++
        "5000-6000 rw-p 00000000 00:00 0 [anon:test]\n";
    try std.testing.expectEqual(@as(?usize, 0x1000), findLibraryBase(maps, "libfoo.so"));
    try std.testing.expectEqual(@as(?usize, 0x3000), findLibraryBase(maps, "libbar.so"));
    try std.testing.expectEqual(@as(?usize, null), findLibraryBase(maps, "libmissing.so"));
}

test "find library base uses the first matching line" {
    const maps =
        "1000-2000 r--p 00000000 00:00 0 /x/libbar.so\n" ++
        "2000-3000 r-xp 00001000 00:00 0 /x/libbar.so\n";
    try std.testing.expectEqual(@as(?usize, 0x1000), findLibraryBase(maps, "libbar.so"));
}
