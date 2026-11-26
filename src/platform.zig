pub const pointer_size = @sizeOf(usize);

pub const method_entry_offset = 0;
pub const method_virtual_entry_offset = pointer_size;

pub const array_header_size = pointer_size * 4;

pub const gc_handle_size = pointer_size;
